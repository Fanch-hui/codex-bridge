import BridgeAgentCore
import BridgeDomain
import BridgeProcess
import BridgeSecurity
import Foundation

public enum AntigravityPermissionEvidence {
  public static func detected(in output: BoundedProcessOutput) -> Bool {
    detected(in: output.head + "\n" + output.tail)
  }

  public static func detected(in value: String?) -> Bool {
    guard let value else { return false }
    let combined = value.lowercased()
    guard !combined.isEmpty else { return false }
    let denialMarkers = [
      "soft-denied",
      "soft denied",
      "auto-denied",
      "auto denied",
      "permission denied",
      "permission was denied",
      "denied permission",
      "user denied permission",
      "requires approval",
      "could not obtain approval",
      "headless mode cannot prompt",
      "not allowed by permission",
      "grant permission",
      "add an allow rule",
      "add an allow-rule",
      "operation was denied by local policy",
    ]
    return denialMarkers.contains { combined.contains($0) }
  }
}

struct AntigravityToolContext: Equatable, Sendable {
  let itemID: String
  let name: String
  let stepIndex: Int
}

public actor AntigravityCLIEventNormalizer {
  private struct ContentState: Sendable {
    var content: String
  }

  private let taskID: TaskID
  private let binding: AgentBinding
  private let projectRoot: String
  private var sequence: Int64 = 0
  private var turnOrdinal = 0
  private var turnSummaries: [String] = []
  private var contents: [String: ContentState] = [:]
  private static let maximumContentBytes = 256 * 1_024
  private static let maximumContentStreams = 64
  private static let maximumLocations = 128

  public init(taskID: TaskID, binding: AgentBinding, projectRoot: String) {
    self.taskID = taskID
    self.binding = binding
    self.projectRoot =
      AntigravityCLILaunchRuntime.canonicalFoundationPath(projectRoot)
      ?? projectRoot
  }

  public func normalize(_ update: AntigravityStepUpdate) throws -> [AgentEventEnvelope] {
    try validateSession(update.conversationID)
    let isKnownState =
      update.state == "ACTIVE" || update.state == "DONE"
      || ((update.stepType == "tool" || update.subagentInfo != nil)
        && AntigravityToolStatus.states.contains(update.state))
    guard update.stepIndex >= 0, isKnownState
    else {
      throw AntigravityCLIError.invalidMessage
    }

    var events: [AgentEventEnvelope] = []
    switch update.stepType {
    case "agent_response":
      if let event = try accumulateContent(update) { events.append(event) }
    case "tool":
      if !Self.isAnonymousPermissionDenial(update) {
        events.append(try tool(update))
      }
    default:
      if update.subagentInfo != nil {
        events.append(try subagent(update))
      }
    }
    if let usage = try usage(update.usage) { events.append(usage) }
    return events
  }

  public func normalize(
    _ result: AntigravityResult,
    permissionDenied: Bool,
    terminal: Bool,
    permissionMode: String? = nil,
    deniedToolItemID: String? = nil,
    deniedToolName: String? = nil
  ) throws -> [AgentEventEnvelope] {
    try validateSession(result.conversationID)
    var events: [AgentEventEnvelope] = []
    if let usage = try usage(result.usage) { events.append(usage) }
    let safeResponse = Self.safeContent(result.response)
    if !safeResponse.isEmpty {
      events.append(
        try envelope(
          .content(
            AgentContentUpdate(
              key: "message:result:\(turnOrdinal)",
              role: .assistant,
              kind: .message,
              mode: .full,
              content: safeResponse,
              isFinal: true,
              authoritative: true
            )
          )
        )
      )
    }
    let turnSummary = Self.summary(
      result.response,
      fallback: "Antigravity completed the task."
    )
    turnSummaries.append(turnSummary)
    let completedTurnOrdinal = turnOrdinal
    turnOrdinal += 1
    contents.removeAll(keepingCapacity: true)

    guard terminal else { return events }
    if permissionDenied {
      let deniedItemID: String
      if let itemID = Self.safeIdentifier(deniedToolItemID),
        Self.safeIdentifier(deniedToolName) != nil
      {
        deniedItemID = itemID
      } else {
        deniedItemID = "antigravity-permission-\(completedTurnOrdinal)"
        events.append(try fallbackPermissionTool(itemID: deniedItemID))
      }
      events.append(try envelope(.approvalAutomaticallyDenied(deniedItemID)))
      events.append(
        try envelope(
          .failed(
            code: "antigravity_permission_denied",
            summary: AntigravityCLIHeadlessPolicy.permissionDeniedSummary(
              permissionMode: permissionMode,
              deniedToolName: deniedToolName
            )
          )
        )
      )
      return events
    }

    let status = result.status.uppercased()
    switch status {
    case "SUCCESS":
      events.append(
        try envelope(
          .completed(
            summary: AgentTurnSummary.combined(turnSummaries) ?? turnSummary,
            stopReason: status
          )
        )
      )
    case "CANCELED", "INTERRUPTED":
      events.append(try envelope(.interrupted))
    default:
      let summary = Self.summary(
        result.error ?? result.response,
        fallback: "Antigravity returned terminal status \(status)."
      )
      events.append(
        try envelope(
          .failed(
            code: "antigravity_\(Self.safeCode(status))",
            summary: summary
          )
        )
      )
    }
    return events
  }

  public func failed(code: String, summary: String) throws -> AgentEventEnvelope {
    try envelope(.failed(code: code, summary: summary))
  }

  public func interrupted() throws -> AgentEventEnvelope {
    try envelope(.interrupted)
  }

  public func steerDispatched(_ text: String) throws -> AgentEventEnvelope {
    try envelope(.steerDispatched(text))
  }

  private func accumulateContent(
    _ update: AntigravityStepUpdate
  ) throws -> AgentEventEnvelope? {
    guard let delta = update.textDelta, !delta.isEmpty else { return nil }
    let key = "message:step:\(update.stepIndex)"
    if contents[key] == nil, contents.count >= Self.maximumContentStreams {
      throw AntigravityCLIError.oversizedFrame
    }
    let existing = contents[key]?.content ?? ""
    let combined = existing + delta
    guard combined.utf8.count <= Self.maximumContentBytes else {
      throw AntigravityCLIError.oversizedFrame
    }
    contents[key] = ContentState(content: combined)
    return try envelope(
      .content(
        AgentContentUpdate(
          key: key,
          role: .assistant,
          kind: .message,
          mode: .delta,
          content: delta
        )
      )
    )
  }

  private func tool(_ update: AntigravityStepUpdate) throws -> AgentEventEnvelope {
    let info = update.toolInfo
    let error = info?.error ?? update.error
    let name = Self.safeIdentifier(info?.name ?? update.toolName) ?? "tool"
    let status = AntigravityToolStatus.resolve(state: update.state, error: error)
    let payload = try AgentToolUpdate(
      key: "tool:\(update.stepIndex)",
      name: name,
      title: name,
      kind: name,
      status: status,
      arguments: Self.safeArguments(info?.parameters),
      output: Self.safeOutput(error?.message ?? info?.output),
      locations: locations(in: info?.parameters),
      childRuns: Self.childRuns(from: update)
    )
    return try envelope(.tool(payload))
  }

  private func fallbackPermissionTool(itemID: String) throws -> AgentEventEnvelope {
    try envelope(
      .tool(
        AgentToolUpdate(
          key: "tool:\(itemID)",
          name: "antigravity_permission",
          title: "Antigravity permission",
          kind: "permission",
          status: .declined
        )
      )
    )
  }

  private func subagent(_ update: AntigravityStepUpdate) throws -> AgentEventEnvelope {
    let subagents = update.subagentInfo?.subagents ?? []
    let children = Self.childRuns(from: update)
    let names = subagents.compactMap { Self.safeIdentifier($0.typeName ?? $0.role) }
    let output = names.isEmpty ? nil : "Subagents: " + names.prefix(16).joined(separator: ", ")
    let payload = try AgentToolUpdate(
      key: "tool:subagent:\(update.stepIndex)",
      name: "subagent",
      title: "Subagent",
      kind: "subagent",
      status: AntigravityToolStatus.resolve(state: update.state, error: update.error),
      output: output,
      childRuns: children
    )
    return try envelope(.tool(payload))
  }

  private static func childRuns(from update: AntigravityStepUpdate) -> [AgentChildRun] {
    let status = AntigravityToolStatus.resolve(state: update.state, error: update.error).rawValue
    return (update.subagentInfo?.subagents ?? []).prefix(32).compactMap { child in
      guard let id = safeIdentifier(child.conversationID) else { return nil }
      let name = safeIdentifier(child.typeName ?? child.role)
      let summary = safeText(update.textDelta, maximumBytes: 4 * 1_024)
      return try? AgentChildRun(
        id: id,
        sessionID: id,
        name: name,
        status: status,
        summary: summary,
        workspaceURLs: child.workspaceURIs?.compactMap {
          safeText($0, maximumBytes: 4 * 1_024)
        } ?? []
      )
    }
  }

  private func usage(_ usage: AntigravityUsage?) throws -> AgentEventEnvelope? {
    guard let total = usage?.totalTokens, total >= 0 else { return nil }
    return try envelope(
      .usage(
        AgentUsageUpdate(
          usedTokens: total,
          contextSize: total,
          costAmount: nil,
          currency: nil
        )
      )
    )
  }

  private func locations(in value: AntigravityJSONValue?) -> [String] {
    guard let value else { return [] }
    var result = Set<String>()
    collectLocations(value, key: nil, depth: 0, into: &result)
    let sorted = result.sorted()
    return Array(sorted[0..<min(sorted.count, Self.maximumLocations)])
  }

  private func collectLocations(
    _ value: AntigravityJSONValue,
    key: String?,
    depth: Int,
    into result: inout Set<String>
  ) {
    guard depth <= 4, result.count < Self.maximumLocations else { return }
    switch value {
    case .object(let object):
      for (childKey, child) in object where result.count < Self.maximumLocations {
        collectLocations(child, key: childKey, depth: depth + 1, into: &result)
      }
    case .array(let values):
      for child in values.prefix(Self.maximumLocations) where result.count < Self.maximumLocations {
        collectLocations(child, key: key, depth: depth + 1, into: &result)
      }
    case .string(let candidate):
      guard Self.isPathKey(key), let path = normalizedProjectPath(candidate) else { return }
      result.insert(path)
    default:
      return
    }
  }

  private func normalizedProjectPath(_ value: String) -> String? {
    guard !value.isEmpty, value.utf8.count <= 4 * 1_024,
      !value.contains("\0"), value.rangeOfCharacter(from: .controlCharacters) == nil
    else { return nil }
    let raw: String
    if value.lowercased().hasPrefix("file://"), let url = URL(string: value), url.isFileURL {
      if let host = url.host, !host.isEmpty,
        host.caseInsensitiveCompare("localhost") != .orderedSame
      {
        raw = "\\\\\(host)\(url.path)"
      } else {
        raw = url.path
      }
    } else {
      raw = value
    }
    let absolute: String
    if AgentPathSemantics.isAbsolute(raw) {
      guard let normalized = AntigravityCLILaunchRuntime.canonicalFoundationPath(raw) else {
        return nil
      }
      absolute = normalized
    } else {
      guard AgentPathSemantics.relativeComponents(raw) != nil else { return nil }
      guard
        let joined = AntigravityCLILaunchRuntime.canonicalFoundationPath(
          URL(fileURLWithPath: projectRoot, isDirectory: true)
            .appendingPathComponent(raw).path
        )
      else {
        return nil
      }
      absolute = joined
    }
    guard AgentPathSemantics.isContained(absolute, in: projectRoot) else { return nil }
    return absolute
  }

  private func validateSession(_ sessionID: String) throws {
    guard binding.providerSessionID == sessionID else {
      throw AntigravityCLIError.sessionMismatch
    }
  }

  private func envelope(_ event: AgentEvent) throws -> AgentEventEnvelope {
    let current = sequence
    sequence += 1
    return try AgentEventEnvelope(
      taskID: taskID,
      providerID: binding.providerID,
      providerSessionID: binding.providerSessionID,
      providerRunID: binding.providerRunID,
      providerSequence: current,
      event: event
    )
  }

  private static func isPathKey(_ key: String?) -> Bool {
    guard let key else { return false }
    let normalized =
      key
      .lowercased()
      .replacingOccurrences(of: "_", with: "")
      .replacingOccurrences(of: "-", with: "")
    return normalized.contains("path")
      || ["file", "source", "destination", "target", "uri", "workspace"].contains(normalized)
  }

  static func toolContext(for update: AntigravityStepUpdate) -> AntigravityToolContext? {
    guard update.stepType == "tool",
      let name = safeIdentifier(update.toolInfo?.name ?? update.toolName)
    else { return nil }
    return AntigravityToolContext(
      itemID: String(update.stepIndex),
      name: name,
      stepIndex: update.stepIndex
    )
  }

  private static func isAnonymousPermissionDenial(_ update: AntigravityStepUpdate) -> Bool {
    guard toolContext(for: update) == nil else { return false }
    return AntigravityPermissionEvidence.detected(in: update.toolInfo?.error?.message)
      || AntigravityPermissionEvidence.detected(in: update.error?.message)
  }

  private static func safeIdentifier(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.utf8.count <= 128,
      !trimmed.contains("\0"), trimmed.rangeOfCharacter(from: .controlCharacters) == nil
    else { return nil }
    return trimmed
  }

  private static func safeArguments(_ value: AntigravityJSONValue?) -> String? {
    guard let encoded = value?.encodedString(), encoded.utf8.count <= 64 * 1_024 else {
      return nil
    }
    return OutboundContentSecurity.redactedToolArguments(encoded, maximumUTF8Bytes: 64 * 1_024)
  }

  private static func safeOutput(_ value: String?) -> String? {
    guard let value else { return nil }
    return OutboundContentSecurity.redactedCommandOutput(
      value,
      maximumUTF8Bytes: 256 * 1_024
    )
  }

  private static func safeText(_ value: String?, maximumBytes: Int) -> String? {
    guard let value, !value.contains("\0") else { return nil }
    return OutboundContentSecurity.redacted(value, maximumUTF8Bytes: maximumBytes)
  }

  private static func safeContent(_ value: String) -> String {
    OutboundContentSecurity.redacted(value, maximumUTF8Bytes: maximumContentBytes)
  }

  private static func summary(_ value: String?, fallback: String) -> String {
    guard let value else { return fallback }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return fallback }
    let redacted = OutboundContentSecurity.redacted(trimmed, maximumUTF8Bytes: 4 * 1_024)
    return redacted.isEmpty ? fallback : redacted
  }

  private static func safeCode(_ value: String) -> String {
    let code = value.lowercased().map { character -> Character in
      character.isLetter || character.isNumber ? character : "_"
    }
    let normalized = String(code).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
    return normalized.isEmpty ? "error" : String(normalized.prefix(64))
  }
}
