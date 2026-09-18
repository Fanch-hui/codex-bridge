import BridgeACP
import BridgeAgentCore
import Foundation

extension DeepSeekHarnessACPClient {
  public func resolvePermission(
    approvalID: String,
    optionID: String
  ) async throws {
    try requireInitialized()
    try validateIdentifier(approvalID, field: "approval.id")
    try validateIdentifier(optionID, field: "approval.optionID")
    guard let request = pendingPermissions[approvalID] else {
      throw AgentRuntimeError.approvalUnavailable(approvalID)
    }
    try requireSession(request.sessionID)
    guard let option = request.options.first(where: { $0.id == optionID }),
      Self.isOneShotPermissionKind(option.kind)
    else {
      throw AgentRuntimeError.approvalUnavailable(optionID)
    }
    pendingPermissions.removeValue(forKey: approvalID)
    do {
      try await broker.send(
        ACPWireMessage(
          id: request.requestID,
          result: Self.permissionSelection(optionID: optionID)
        )
      )
    } catch {
      let mapped = Self.map(error)
      await failConnection(mapped)
      throw mapped
    }
  }

  func handleServerRequest(
    id: ACPRequestID,
    method: String,
    params: ACPJSONValue?
  ) async {
    do {
      guard method == "session/request_permission" else {
        try await broker.send(
          ACPWireMessage(
            id: id,
            error: ACPWireError(code: -32601, message: "Method not found")
          )
        )
        return
      }
      guard pendingPermissions.count < DeepSeekHarnessACPConstants.maximumPendingPermissions else {
        throw AgentRuntimeError.approvalUnavailable("capacity")
      }
      let permission = try Self.parsePermission(
        params,
        requestID: id,
        approvalID: try nextApprovalID()
      )
      try requireSession(permission.sessionID)
      guard pendingPermissions[permission.approvalID] == nil else {
        throw AgentRuntimeError.approvalUnavailable(permission.approvalID)
      }
      pendingPermissions[permission.approvalID] = permission
      yield(.permissionRequested(permission))
    } catch {
      try? await broker.send(
        ACPWireMessage(
          id: id,
          error: Self.permissionRequestError(error)
        )
      )
    }
  }

  private func nextApprovalID() throws -> String {
    for _ in 0..<8 {
      let value = "deepseek-\(UUID().uuidString.lowercased())"
      if pendingPermissions[value] == nil { return value }
    }
    throw AgentRuntimeError.approvalUnavailable("id")
  }

  private static func parsePermission(
    _ value: ACPJSONValue?,
    requestID: ACPRequestID,
    approvalID: String
  ) throws -> DeepSeekHarnessACPPermissionRequest {
    guard let object = value?.objectValue,
      let sessionID = object["sessionId"]?.stringValue,
      let toolCall = object["toolCall"]?.objectValue,
      let toolCallID = toolCall["toolCallId"]?.stringValue,
      let values = object["options"]?.arrayValue,
      !values.isEmpty,
      values.count <= 16
    else {
      throw DeepSeekHarnessACPError.malformedPermission
    }
    try validateIdentifier(sessionID, field: "permission.sessionID")
    try validateIdentifier(toolCallID, field: "permission.toolCallID")
    let title = toolCall["title"]?.stringValue ?? "DeepSeek Harness permission request"
    guard !title.isEmpty, title.utf8.count <= 1_024, !title.contains("\0"),
      title.rangeOfCharacter(from: .controlCharacters) == nil
    else {
      throw DeepSeekHarnessACPError.malformedPermission
    }
    if let kind = toolCall["kind"]?.stringValue {
      try validateIdentifier(kind, field: "permission.toolKind")
    }
    let options = try values.compactMap { value -> AgentApprovalOption? in
      guard let option = value.objectValue,
        let optionID = option["optionId"]?.stringValue,
        let name = option["name"]?.stringValue,
        let kind = option["kind"]?.stringValue
      else {
        throw DeepSeekHarnessACPError.malformedPermission
      }
      guard isOneShotPermissionKind(kind) else { return nil }
      do {
        return try AgentApprovalOption(id: optionID, name: name, kind: kind)
      } catch {
        throw DeepSeekHarnessACPError.malformedPermission
      }
    }
    guard !options.isEmpty else {
      throw AgentRuntimeError.capabilityUnavailable(.sessionRuleApproval)
    }
    guard Set(options.map(\.id)).count == options.count,
      options.contains(where: { isRejectOnce($0.kind) })
    else {
      throw DeepSeekHarnessACPError.missingRejectOnce
    }
    let rawInput = toolCall["rawInput"]
    if let rawInput {
      guard let data = try? JSONEncoder().encode(rawInput),
        data.count <= DeepSeekHarnessACPConstants.maximumPermissionInputBytes
      else {
        throw DeepSeekHarnessACPError.malformedPermission
      }
    }
    return DeepSeekHarnessACPPermissionRequest(
      approvalID: approvalID,
      requestID: requestID,
      sessionID: sessionID,
      toolCallID: toolCallID,
      title: title,
      kind: toolCall["kind"]?.stringValue,
      rawInput: rawInput,
      options: options,
    )
  }

  private static func isRejectOnce(_ value: String) -> Bool {
    value.replacingOccurrences(of: "-", with: "_").lowercased() == "reject_once"
  }

  private static func isOneShotPermissionKind(_ value: String) -> Bool {
    isAllowOnce(value) || isRejectOnce(value)
  }

  private static func isAllowOnce(_ value: String) -> Bool {
    value.replacingOccurrences(of: "-", with: "_").lowercased() == "allow_once"
  }

  private static func permissionRequestError(_ error: any Error) -> ACPWireError {
    if case AgentRuntimeError.capabilityUnavailable(.sessionRuleApproval) = error {
      return ACPWireError(
        code: -32001,
        message: "DeepSeek Harness supports one-shot permission options only."
      )
    }
    return ACPWireError(code: -32602, message: "Invalid permission request")
  }

  static func rejectOptionID(in options: [AgentApprovalOption]) -> String {
    options.first(where: { isRejectOnce($0.kind) })?.id ?? "reject-once"
  }

  static func permissionSelection(optionID: String) -> ACPJSONValue {
    .object([
      "outcome": .object([
        "outcome": .string("selected"),
        "optionId": .string(optionID),
      ])
    ])
  }
}
