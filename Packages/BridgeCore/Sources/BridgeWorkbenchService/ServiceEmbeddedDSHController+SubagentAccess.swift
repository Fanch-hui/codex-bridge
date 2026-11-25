import BridgeACP
import BridgeEmbeddedDSH
import BridgeMCP
import BridgeServiceCore
import Foundation

/// What a connected child may do, relative to its root session. A child can be narrowed to
/// read-only when it is started, never widened; a continuation keeps the access it started with.
extension ServiceEmbeddedDSHController {
  static let readOnlySubagentAccess = "read-only"

  private static func subagentAccessKey(_ workspaceID: String) -> String {
    "embedded_dsh.workspace.access." + workspaceID
  }

  /// The `access` the engine asked for; nil keeps the root session's permission.
  static func requestedSubagentAccess(_ payload: [String: ACPJSONValue]) throws -> String? {
    guard let value = payload["access"], value != .null else { return nil }
    guard value.stringValue == readOnlySubagentAccess else {
      throw ServiceStoreError.invalidArgument("embedded_dsh.access")
    }
    return readOnlySubagentAccess
  }

  /// The permission a child runs with. A read-only root makes every child read-only, whatever it
  /// asks for. For a continuation the stored access wins over the payload, so a later message
  /// cannot lift a restriction.
  func subagentPermission(
    _ payload: [String: ACPJSONValue], execution: EmbeddedDSHExecution, rootID: String,
    childID: String, continuation: Bool
  ) async throws -> ServicePermissionMode {
    guard execution.permissionMode == .full else { return .readOnly }
    let access: String?
    if continuation {
      let id = Self.workspaceID(rootID: rootID, childID: childID)
      access = try await store.setting(key: Self.subagentAccessKey(id))?.value
    } else {
      access = try Self.requestedSubagentAccess(payload)
    }
    return access == Self.readOnlySubagentAccess ? .readOnly : .full
  }

  /// Remembers a read-only start before its task exists, so every later round of the child
  /// resolves the same permission even if the root session's permission changes meanwhile.
  func recordSubagentAccess(
    _ permission: ServicePermissionMode, rootID: String, childID: String
  ) async throws {
    guard permission == .readOnly else { return }
    let id = Self.workspaceID(rootID: rootID, childID: childID)
    try await store.setSetting(
      ServiceSettingRecord(
        key: Self.subagentAccessKey(id), value: Self.readOnlySubagentAccess, updatedAt: Date()))
  }

  /// A provider without read-only enforcement is refused rather than run with write access.
  func submitReadOnlyAware(
    _ submission: MCPServiceTaskSubmission, rootID: String, childID: String,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPServiceTaskSubmissionReceipt {
    do {
      return try await dispatchSubagentSubmission(
        submission, rootID: rootID, childID: childID, deadline: deadline)
    } catch BridgeMCPQueryError.agentPermissionUnsupported {
      throw ServiceStoreError.invalidArgument("embedded_dsh.read_only_unsupported")
    }
  }
}
