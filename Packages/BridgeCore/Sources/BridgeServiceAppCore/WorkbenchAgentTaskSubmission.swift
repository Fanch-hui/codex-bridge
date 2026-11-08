import BridgeAgentCore
import BridgeIPC
import Foundation

/// Validates a task the user starts by hand from the web workbench inspector.
///
/// Codex is addressed by provider ID without an installation; every other
/// Agent must name an enabled, available installation of that provider.
public enum WorkbenchAgentTaskSubmission {
  public static let codexProviderID = "codex"
  public static let maximumPromptBytes = 32 * 1_024
  public static let permissionModes: Set<String> = ["read-only", "full"]

  public static func request(
    projectID: String?,
    providerID: String?,
    installationID: String?,
    prompt: String?,
    model: String? = nil,
    effort: String? = nil,
    permissionMode: String?,
    clientRequestID: String,
    registeredProjectIDs: Set<String>,
    installations: [IPCAgentInstallationSummary]
  ) throws -> IPCAgentSubmitRequest {
    guard let projectID, registeredProjectIDs.contains(projectID) else {
      throw SubmissionError.projectUnavailable
    }
    guard let providerID, !providerID.isEmpty else { throw SubmissionError.agentUnavailable }
    let resolvedInstallationID: String?
    if providerID == codexProviderID {
      guard installationID?.isEmpty != false else { throw SubmissionError.agentUnavailable }
      resolvedInstallationID = nil
    } else {
      guard let installationID,
        installations.contains(where: {
          $0.installationID == installationID && $0.providerID == providerID
            && $0.isEnabled && $0.availability == "available"
        })
      else { throw SubmissionError.agentUnavailable }
      resolvedInstallationID = installationID
    }
    guard let permissionMode, permissionModes.contains(permissionMode) else {
      throw SubmissionError.invalidPermission
    }
    guard let prompt, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      prompt.utf8.count <= maximumPromptBytes, !prompt.contains("\0"),
      !clientRequestID.isEmpty, clientRequestID.utf8.count <= 512,
      !clientRequestID.contains("\0")
    else { throw SubmissionError.invalidInput }
    let model = try selection(model, maximumBytes: 256)
    let effort = try selection(effort, maximumBytes: 64)
    return IPCAgentSubmitRequest(
      projectID: projectID,
      providerID: providerID,
      installationID: resolvedInstallationID,
      model: model,
      effort: effort,
      permissionMode: permissionMode,
      prompt: prompt,
      modelOverride: model != nil || effort != nil,
      clientRequestID: clientRequestID,
      queueIfBusy: true
    )
  }

  static func selection(_ value: String?, maximumBytes: Int) throws -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.utf8.count <= maximumBytes,
      trimmed.rangeOfCharacter(from: .controlCharacters) == nil
    else { throw SubmissionError.invalidInput }
    return trimmed.isEmpty || trimmed == "provider-default" ? nil : trimmed
  }

  /// Errors the user can fix in the same form keep the typed instruction editable.
  public static func canEditInput(after error: any Error) -> Bool? {
    if error is SubmissionError { return true }
    guard let error = error as? BridgeServiceIPCCodecError,
      case .remoteError(let remote) = error,
      ["agent_model_unavailable", "agent_permission_unsupported", "skill_not_found"]
        .contains(remote.code)
    else { return nil }
    return true
  }

  public enum SubmissionError: Error, LocalizedError, Equatable {
    case projectUnavailable
    case agentUnavailable
    case invalidPermission
    case invalidInput

    public var errorDescription: String? {
      switch self {
      case .projectUnavailable: "请选择已登记的项目。"
      case .agentUnavailable: "所选 Agent 当前不可用，请在连接页确认已启用并连接。"
      case .invalidPermission: "请选择只读或完整权限。"
      case .invalidInput: "指令或模型选择无效，指令最多为 32 KB。"
      }
    }
  }
}
