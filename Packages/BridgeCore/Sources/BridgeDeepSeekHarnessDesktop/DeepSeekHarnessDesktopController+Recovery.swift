import BridgeACP
import BridgeAgentCore
import Foundation

public enum DeepSeekHarnessDesktopReconciledRun: Equatable, Sendable {
  case completed(summary: String)
  case failed(code: String, summary: String)
  case interrupted
}

extension DeepSeekHarnessDesktopController {
  /// Reconciles an existing Bridge-owned input without submitting another input.
  public func reconcileRun(
    installation: AgentInstallation,
    runtime: AgentRuntimeBinding,
    sessionID: String?,
    projectRoot: String,
    timeout: Duration = .seconds(25)
  ) async throws -> DeepSeekHarnessDesktopReconciledRun {
    guard runtime.connectionMode == .nativeDesktop, !runtime.requestID.isEmpty,
      !runtime.requestID.contains("\0"), timeout > .zero
    else { throw AgentRuntimeError.invalidRequest("dsh.desktop.recovery") }
    return try await withThrowingTaskGroup(of: DeepSeekHarnessDesktopReconciledRun.self) { group in
      group.addTask {
        try await self.reconcileOwnedRun(
          installation: installation, runtime: runtime, sessionID: sessionID,
          projectRoot: projectRoot)
      }
      group.addTask {
        try await Task.sleep(for: timeout)
        throw AgentRuntimeError.timedOut
      }
      defer { group.cancelAll() }
      guard let result = try await group.next() else { throw AgentRuntimeError.processUnavailable }
      return result
    }
  }

  private func reconcileOwnedRun(
    installation: AgentInstallation, runtime: AgentRuntimeBinding,
    sessionID: String?, projectRoot: String
  ) async throws -> DeepSeekHarnessDesktopReconciledRun {
    guard let trust = try await configuration.trustProvider(installation.id),
      runtime.profileID.map({ $0 == trust.profileID }) ?? true
    else { throw AgentRuntimeError.sessionMismatch }
    if try await configuration.desktopRunning(installation) == false {
      throw AgentRuntimeError.processUnavailable
    }
    let client = try await client(installation, profileID: runtime.profileID)
    try await authorizeProject(projectRoot, client: client)
    var state = DesktopRecoveredRun(requestID: runtime.requestID, sessionID: sessionID)
    var cancellationRequested = false
    while true {
      try Task.checkCancellation()
      let observation = try await client.call(
        "run/observe",
        params: [
          "requestID": .string(runtime.requestID), "cursor": .integer(state.cursor),
        ])
      if let outcome = try state.consume(observation) { return outcome }
      if !cancellationRequested {
        let reply = try await client.call(
          "run/cancel", params: ["requestID": .string(runtime.requestID)])
        try state.validateIdentity(reply)
        cancellationRequested = true
      }
      try await Task.sleep(for: .milliseconds(200))
    }
  }
}

private struct DesktopRecoveredRun {
  let requestID: String
  var sessionID: String?
  var cursor: Int64 = 0
  private var messages: [String: String] = [:]
  private var messageOrder: [String] = []
  private var failure: (code: String, summary: String)?

  init(requestID: String, sessionID: String?) {
    self.requestID = requestID
    self.sessionID = sessionID
  }

  mutating func validateIdentity(_ value: ACPJSONValue) throws {
    guard value["requestID"]?.stringValue == requestID,
      let observedSession = value["sessionID"]?.stringValue, !observedSession.isEmpty,
      sessionID.map({ $0 == observedSession }) ?? true
    else { throw AgentRuntimeError.sessionMismatch }
    sessionID = observedSession
  }

  mutating func consume(_ value: ACPJSONValue) throws -> DeepSeekHarnessDesktopReconciledRun? {
    try validateIdentity(value)
    guard let events = value["events"]?.arrayValue,
      let end = value["cursor"]?.intValue, Int64(end) >= cursor,
      let status = value["status"]?.stringValue
    else { throw AgentRuntimeError.malformedEvent("dsh_desktop_recovery_observation") }
    for event in events {
      guard event["requestID"]?.stringValue == requestID,
        let position = event["cursor"]?.intValue, Int64(position) > cursor, position <= end,
        let type = event["eventType"]?.stringValue, let data = event["data"]
      else { throw AgentRuntimeError.malformedEvent("dsh_desktop_recovery_event") }
      cursor = Int64(position)
      if type == "message", data["role"]?.stringValue == "assistant",
        let content = data["content"]?.stringValue
      {
        let key = data["messageID"]?.stringValue ?? "message-\(position)"
        if messages[key] == nil { messageOrder.append(key) }
        messages[key] = AgentProgressText.bounded(
          content, maximumBytes: AgentProgressText.maximumContentBytes)
      } else if type == "failed" {
        failure = (
          data["code"]?.stringValue ?? "desktop_run_failed",
          data["message"]?.stringValue ?? "DSH 原生任务执行失败。"
        )
      }
    }
    guard cursor == Int64(end) else {
      throw AgentRuntimeError.malformedEvent("dsh_desktop_recovery_cursor")
    }
    switch status {
    case "running": return nil
    case "completed":
      return .completed(summary: messageOrder.compactMap { messages[$0] }.joined(separator: "\n\n"))
    case "failed":
      return .failed(
        code: failure?.code ?? "desktop_run_failed",
        summary: failure?.summary ?? "DSH 原生任务执行失败。")
    case "cancelled": return .interrupted
    default: throw AgentRuntimeError.malformedEvent("dsh_desktop_recovery_status")
    }
  }
}
