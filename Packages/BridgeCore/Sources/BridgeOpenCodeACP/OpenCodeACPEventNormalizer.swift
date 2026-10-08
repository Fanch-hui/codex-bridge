import BridgeACP
import BridgeAgentCore
import BridgeDomain
import Foundation

public actor OpenCodeACPEventNormalizer {
  private struct ContentState: Sendable {
    let role: AgentContentRole
    let kind: AgentContentKind
    var buffer = AgentProgressTextBuffer()
  }

  private struct ToolState: Sendable {
    var title: String?
    var kind: String?
    var arguments: String?
    var output: String?
    var locations: [String] = []
    var childRuns: [AgentChildRun] = []
    var status: AgentToolStatus = .pending
  }

  private let taskID: TaskID
  private let binding: AgentBinding
  private let projectRoot: String?
  private var sequence: Int64 = 0
  private var contentOrder: [String] = []
  private var contents: [String: ContentState] = [:]
  private var completedTurnSummaries: [String] = []
  private var tools: [String: ToolState] = [:]
  private static let maximumContentStreams = 64

  public init(taskID: TaskID, binding: AgentBinding, projectRoot: String? = nil) {
    self.taskID = taskID
    self.binding = binding
    self.projectRoot = projectRoot.flatMap {
      OpenCodeACPPathSupport.canonicalFilesystemPath($0, resolvingSymlinks: false)
    }
  }

  public func normalize(_ event: OpenCodeACPClientEvent) throws -> AgentEventEnvelope? {
    switch event {
    case .permissionRequested(let request):
      try validateSession(request.sessionID)
      return try approval(request)
    case .notification(let notification):
      return try normalize(notification)
    }
  }

  public func completed(stopReason: String, summary: String? = nil) throws -> AgentEventEnvelope {
    guard
      let resolvedSummary =
        summary
        ?? AgentTurnSummary.combined(completedTurnSummaries)
        ?? latestAssistantSummary(),
      !resolvedSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      throw OpenCodeACPError.malformedResponse
    }
    return try envelope(.completed(summary: resolvedSummary, stopReason: stopReason))
  }

  public func finalizeContent() throws -> [AgentEventEnvelope] {
    let events = try contentOrder.compactMap { key -> AgentEventEnvelope? in
      guard let state = contents[key], state.role == .assistant, state.kind == .message,
        !state.buffer.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else {
        return nil
      }
      let update = try AgentContentUpdate(
        key: key,
        role: state.role,
        kind: state.kind,
        mode: .full,
        content: state.buffer.content,
        baseContentLength: nil,
        isFinal: true,
        authoritative: true
      )
      return try envelope(.content(update))
    }
    if let turnSummary = latestAssistantSummary() {
      completedTurnSummaries.append(turnSummary)
    }
    contentOrder.removeAll(keepingCapacity: true)
    contents.removeAll(keepingCapacity: true)
    return events
  }

  public func steerDispatched(_ text: String) throws -> AgentEventEnvelope {
    try envelope(.steerDispatched(text))
  }

  public func unfinishedToolCount() -> Int {
    tools.values.reduce(into: 0) { count, state in
      if state.status == .pending || state.status == .inProgress {
        count += 1
      }
    }
  }

  public func failed(code: String, summary: String) throws -> AgentEventEnvelope {
    try envelope(.failed(code: code, summary: summary))
  }

  public func interrupted() throws -> AgentEventEnvelope {
    try envelope(.interrupted)
  }

  private func normalize(_ notification: OpenCodeACPNotification) throws -> AgentEventEnvelope? {
    guard notification.method == "session/update" else { return nil }
    guard let params = notification.params?.objectValue,
      let sessionID = params["sessionId"]?.stringValue,
      let update = params["update"]?.objectValue,
      let updateType = update["sessionUpdate"]?.stringValue
    else {
      throw OpenCodeACPError.invalidMessage
    }
    try validateSession(sessionID)

    switch updateType {
    case "agent_message_chunk":
      return try content(update, role: .assistant, kind: .message, fallbackKey: "message:assistant")
    case "user_message_chunk":
      return try content(update, role: .user, kind: .message, fallbackKey: "message:user")
    case "agent_thought_chunk":
      return try content(
        update, role: .assistant, kind: .reasoning, fallbackKey: "reasoning:assistant")
    case "tool_call", "tool_call_update":
      return try tool(update)
    case "plan":
      return try plan(update)
    case "usage_update":
      return try usage(update)
    default:
      return nil
    }
  }

  private func content(
    _ update: [String: ACPJSONValue],
    role: AgentContentRole,
    kind: AgentContentKind,
    fallbackKey: String
  ) throws -> AgentEventEnvelope? {
    guard let content = update["content"]?.objectValue,
      content["type"]?.stringValue == "text",
      let text = content["text"]?.stringValue,
      !text.isEmpty
    else { return nil }
    let rawMessageID = update["messageId"]?.stringValue
    let key = rawMessageID.map { "\(fallbackKey):\($0)" } ?? fallbackKey
    let existing = contents[key]
    if let existing, existing.role != role || existing.kind != kind {
      throw OpenCodeACPError.invalidMessage
    }
    if existing == nil, contents.count >= Self.maximumContentStreams { return nil }
    var state = existing ?? ContentState(role: role, kind: kind)
    guard let payload = try state.buffer.append(text, key: key, role: role, kind: kind) else {
      return nil
    }
    if existing == nil { contentOrder.append(key) }
    contents[key] = state
    return try envelope(.content(payload))
  }

  private func tool(_ update: [String: ACPJSONValue]) throws -> AgentEventEnvelope? {
    guard let toolCallID = update["toolCallId"]?.stringValue, !toolCallID.isEmpty else {
      throw OpenCodeACPError.invalidMessage
    }
    var state = tools[toolCallID] ?? ToolState()
    if let title = update["title"]?.stringValue { state.title = title }
    if let kind = update["kind"]?.stringValue { state.kind = kind }
    if let status = update["status"]?.stringValue,
      let normalizedStatus = Self.toolStatus(status)
    {
      state.status = normalizedStatus
    }
    if let rawInput = update["rawInput"] {
      state.arguments =
        rawInput.progressOmissionDisplay
        ?? rawInput.encodedString().map {
          $0.utf8.count > 64 * 1_024 ? AgentProgressText.omissionMarker : $0
        }
      state.childRuns =
        rawInput.originalProgressInput.map {
          Self.childRuns(from: $0, title: state.title, kind: state.kind, status: state.status)
        } ?? []
      if let input = rawInput.objectValue {
        state.locations = Array(
          Set(state.locations + Self.absoluteLocations(from: input, projectRoot: projectRoot))
        ).sorted()
      }
    }
    if let output = Self.toolOutput(update["content"]) {
      state.output = AgentProgressText.bounded(output, maximumBytes: 256 * 1_024)
    }
    if let locations = update["locations"]?.arrayValue {
      state.locations = locations.prefix(128).compactMap { value in
        guard let path = value["path"]?.stringValue,
          let absolute = Self.absolutePath(path, projectRoot: projectRoot)
        else { return nil }
        return absolute
      }
      state.locations = Array(Set(state.locations)).sorted()
    }
    let name = Self.semanticToolName(title: state.title, kind: state.kind)
    let payload = try AgentToolUpdate(
      key: "tool:\(toolCallID)",
      name: name,
      title: state.title,
      kind: state.kind,
      status: state.status,
      arguments: state.arguments,
      output: state.output,
      locations: state.locations,
      childRuns: state.childRuns
    )
    if state.status == .pending || state.status == .inProgress {
      tools[toolCallID] = state
    } else {
      tools[toolCallID] = ToolState(status: state.status)
    }
    return try envelope(.tool(payload))
  }

  private static func semanticToolName(title: String?, kind: String?) -> String {
    let values = [title, kind].compactMap { normalizedWords($0) }
    let tokens = Set(values.flatMap { $0.split(separator: "_").map(String.init) })

    if tokens.contains("web") || tokens.contains("browser") || tokens.contains("internet") {
      if tokens.contains("search") || tokens.contains("query") || tokens.contains("lookup") {
        return "web_search"
      }
      if tokens.contains("fetch") || tokens.contains("read") || tokens.contains("open")
        || tokens.contains("url") || tokens.contains("page") || tokens.contains("content")
      {
        return "web_fetch"
      }
    }
    if tokens.contains("url") && (tokens.contains("read") || tokens.contains("fetch")) {
      return "web_fetch"
    }
    if tokens.contains("task") || tokens.contains("agent") || tokens.contains("subagent")
      || tokens.contains("delegate") || tokens.contains("explore")
    {
      return "subagent"
    }
    if values.contains("think") {
      // A real `think` tool is analysis, not evidence of a child run.
      return "think"
    }
    if values.contains(where: { ["search", "grep", "glob", "find"].contains($0) }) {
      return "search_files"
    }
    if values.contains(where: { ["read", "read_file"].contains($0) }) {
      return "read_files"
    }
    if values.contains(where: { ["list", "list_files", "list_directory"].contains($0) }) {
      return "list_files"
    }
    if values.contains(where: {
      ["edit", "write", "patch", "delete", "move", "file_change"].contains($0)
    }) {
      return "file_change"
    }
    if values.contains(where: { ["execute", "command", "bash", "shell", "exec"].contains($0) }) {
      return "command_execution"
    }
    return normalizedWords(kind) ?? normalizedWords(title) ?? "tool"
  }

  private static func normalizedWords(_ value: String?) -> String? {
    guard let value else { return nil }
    let bounded = String(decoding: value.utf8.prefix(192), as: UTF8.self)
    let normalized =
      bounded
      .lowercased()
      .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
      .joined(separator: "_")
    return normalized.isEmpty ? nil : normalized
  }

  private static func childRuns(
    from input: ACPJSONValue,
    title: String?,
    kind: String?,
    status: AgentToolStatus
  ) -> [AgentChildRun] {
    guard semanticToolName(title: title, kind: kind) == "subagent",
      let object = input.objectValue
    else { return [] }
    let id = [
      "childSessionId", "child_session_id", "sessionId", "session_id", "conversationId",
      "conversation_id", "agentId", "agent_id",
    ]
    .compactMap { object[$0]?.stringValue }
    .first
    .flatMap(ACPApprovalSanitizer.safeText)
    guard let id else { return [] }
    let name =
      ["name", "role", "agent"].compactMap { object[$0]?.stringValue }
      .first.flatMap(ACPApprovalSanitizer.safeText)
      ?? title.flatMap(ACPApprovalSanitizer.safeText)
    let summary = ["summary", "result", "description"].compactMap { object[$0]?.stringValue }
      .first.flatMap(ACPApprovalSanitizer.safeText)
    guard
      let child = try? AgentChildRun(
        id: id,
        sessionID: object["sessionId"]?.stringValue ?? object["session_id"]?.stringValue,
        name: name,
        status: status.rawValue,
        summary: summary
      )
    else { return [] }
    return [child]
  }

  private func plan(_ update: [String: ACPJSONValue]) throws -> AgentEventEnvelope? {
    guard let rawEntries = update["entries"]?.arrayValue else { return nil }
    var entries = try rawEntries.prefix(rawEntries.count > 64 ? 63 : 64).compactMap {
      value -> AgentPlanEntry? in
      guard let object = value.objectValue,
        let content = object["content"]?.stringValue,
        !content.isEmpty
      else { return nil }
      return try AgentPlanEntry(
        content: content,
        priority: object["priority"]?.stringValue,
        status: object["status"]?.stringValue
      )
    }
    if rawEntries.count > 64 {
      entries.append(try AgentPlanEntry(content: "[…计划过长，后续已省略]"))
    }
    return entries.isEmpty ? nil : try envelope(.plan(entries))
  }

  private func usage(_ update: [String: ACPJSONValue]) throws -> AgentEventEnvelope? {
    guard let used = update["used"]?.intValue,
      let size = update["size"]?.intValue
    else { return nil }
    let cost = update["cost"]?.objectValue
    let payload = try AgentUsageUpdate(
      usedTokens: used,
      contextSize: size,
      costAmount: cost?["amount"]?.doubleValue,
      currency: cost?["currency"]?.stringValue
    )
    return try envelope(.usage(payload))
  }

  private func approval(
    _ request: OpenCodeACPPermissionRequest
  ) throws -> AgentEventEnvelope {
    let title = request.title.trimmingCharacters(in: .whitespacesAndNewlines)
    let safeTitle = ACPApprovalSanitizer.safeText(title) ?? "OpenCode permission request"
    let input = request.rawInput?.objectValue ?? [:]
    let relativePaths = Self.relativePaths(from: input, projectRoot: projectRoot)
    let approval = try AgentApprovalRequest(
      approvalID: request.approvalID,
      taskID: taskID,
      binding: binding,
      providerItemID: request.toolCallID,
      kind: Self.approvalKind(request.kind),
      title: safeTitle,
      relativePaths: relativePaths,
      normalizedCommand: ACPApprovalSanitizer.safeCommand(input["command"]?.stringValue),
      networkTarget: ACPApprovalSanitizer.safeNetworkTarget(
        input["url"]?.stringValue
          ?? input["uri"]?.stringValue
          ?? input["target"]?.stringValue
      ),
      options: request.options
    )
    return try envelope(.approvalRequested(approval))
  }

  private func validateSession(_ sessionID: String) throws {
    guard binding.providerSessionID == sessionID else {
      throw OpenCodeACPError.sessionMismatch
    }
  }

  private func latestAssistantSummary() -> String? {
    for key in contentOrder.reversed() {
      guard let state = contents[key], state.role == .assistant, state.kind == .message else {
        continue
      }
      let trimmed = state.buffer.content.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { continue }
      return String(decoding: trimmed.utf8.prefix(4 * 1_024), as: UTF8.self)
    }
    return nil
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

  private static func toolStatus(_ value: String) -> AgentToolStatus? {
    switch value {
    case "pending": .pending
    case "in_progress": .inProgress
    case "completed": .completed
    case "failed": .failed
    case "cancelled": .cancelled
    case "declined": .declined
    default: nil
    }
  }

  private static func approvalKind(_ value: String?) -> AgentApprovalKind {
    switch value?.lowercased() {
    case "execute", "command", "bash", "shell":
      .command
    case "edit", "file", "file_change", "create", "delete", "move", "write":
      .fileChange
    case "network", "webfetch", "websearch", "fetch":
      .network
    case "read", "glob", "grep", "list", "lsp", "tool":
      .tool
    default:
      .unknown
    }
  }

  private static func relativePaths(
    from input: [String: ACPJSONValue],
    projectRoot: String?
  ) -> [String] {
    guard let projectRoot else { return [] }
    let keys = [
      "path", "filePath", "filepath", "file_path", "file", "source", "destination",
    ]
    let values = keys.compactMap { input[$0]?.stringValue }
    var paths = Set<String>()
    for value in values {
      guard let path = relativePath(value, projectRoot: projectRoot) else { continue }
      paths.insert(path)
    }
    return paths.sorted()
  }

  private static func relativePath(_ value: String, projectRoot: String) -> String? {
    guard !value.isEmpty, value.utf8.count <= 1_024,
      !value.contains("\0"), value.rangeOfCharacter(from: .controlCharacters) == nil
    else { return nil }
    let relative: String
    if AgentPathSemantics.isAbsolute(value) {
      guard
        let canonical = OpenCodeACPPathSupport.canonicalFilesystemPath(
          value,
          resolvingSymlinks: false
        ),
        let contained = AgentPathSemantics.relativePath(canonical, from: projectRoot),
        !contained.isEmpty
      else {
        return nil
      }
      relative = contained
    } else {
      guard AgentPathSemantics.relativeComponents(value) != nil else { return nil }
      relative = value
    }
    guard AgentPathSemantics.relativeComponents(relative) != nil,
      !ACPApprovalSanitizer.containsSensitiveMarker(relative.lowercased())
    else { return nil }
    return relative
  }

  private static func toolOutput(_ value: ACPJSONValue?) -> String? {
    guard let items = value?.arrayValue else { return nil }
    let lines = items.compactMap { item -> String? in
      guard let object = item.objectValue, let type = object["type"]?.stringValue else {
        return nil
      }
      if type == "content",
        let content = object["content"]?.objectValue,
        content["type"]?.stringValue == "text"
      {
        return content["text"]?.stringValue
      }
      if type == "diff", let path = object["path"]?.stringValue {
        return "Diff: \(path)"
      }
      return nil
    }
    return lines.isEmpty ? nil : lines.joined(separator: "\n")
  }
}
