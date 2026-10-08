import BridgeAgentCore
import BridgeIPC
import Foundation

public enum DSHWorkbenchTaskSubmission {
  public static let providerID = AgentProviderID.deepSeekHarness.rawValue
  public static let maximumPromptBytes = 32 * 1_024

  public static func request(
    projectID: String?,
    installationID: String?,
    prompt: String?,
    model: String? = nil,
    effort: String? = nil,
    skillNames: [String]? = nil,
    attachmentPaths: [String]? = nil,
    permissionMode: String,
    clientRequestID: String,
    queueIfBusy: Bool = false,
    registeredProjectIDs: Set<String>,
    installations: [IPCAgentInstallationSummary]
  ) throws -> IPCAgentSubmitRequest {
    guard let projectID, registeredProjectIDs.contains(projectID) else {
      throw SubmissionError.projectUnavailable
    }
    guard let installationID,
      installations.contains(where: {
        $0.installationID == installationID && $0.providerID == providerID
          && $0.isEnabled && $0.availability == "available"
      })
    else {
      throw SubmissionError.installationUnavailable
    }
    guard permissionMode == "full" else { throw SubmissionError.permissionUnsupported }
    guard let prompt, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      prompt.utf8.count <= maximumPromptBytes, !prompt.contains("\0"),
      !clientRequestID.isEmpty, clientRequestID.utf8.count <= 512,
      !clientRequestID.contains("\0")
    else {
      throw SubmissionError.invalidInput
    }
    let model = try selection(model, maximumBytes: 256)
    let effort = try selection(effort, maximumBytes: 64)
    guard skillNames?.count ?? 0 <= 16,
      skillNames?.allSatisfy({
        !$0.isEmpty && $0.utf8.count <= 128
          && $0.rangeOfCharacter(from: .controlCharacters) == nil
      }) != false
    else { throw SubmissionError.invalidInput }
    if let attachmentPaths {
      guard attachmentPaths.count <= AgentImageAttachmentLimits.maximumCount,
        Set(attachmentPaths).count == attachmentPaths.count,
        attachmentPaths.allSatisfy({
          !$0.isEmpty && $0.utf8.count <= 2_048
            && $0.rangeOfCharacter(from: .controlCharacters) == nil
        })
      else { throw SubmissionError.invalidInput }
    }
    return IPCAgentSubmitRequest(
      projectID: projectID,
      providerID: providerID,
      installationID: installationID,
      model: model,
      effort: effort,
      permissionMode: permissionMode,
      prompt: prompt,
      skillNames: skillNames,
      modelOverride: model != nil || effort != nil,
      clientRequestID: clientRequestID,
      queueIfBusy: queueIfBusy,
      attachmentPaths: attachmentPaths
    )
  }

  private static func selection(_ value: String?, maximumBytes: Int) throws -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.utf8.count <= maximumBytes,
      trimmed.rangeOfCharacter(from: .controlCharacters) == nil
    else { throw SubmissionError.invalidInput }
    return trimmed.isEmpty || trimmed == "provider-default" ? nil : trimmed
  }

  public static func canEditInput(after error: any Error) -> Bool? {
    guard let error = error as? BridgeServiceIPCCodecError,
      case .remoteError(let remote) = error,
      ["agent_model_unavailable", "agent_permission_unsupported", "skill_not_found"]
        .contains(remote.code)
    else { return nil }
    return true
  }

  public enum SubmissionError: Error, LocalizedError, Equatable {
    case projectUnavailable
    case installationUnavailable
    case permissionUnsupported
    case invalidInput

    public var errorDescription: String? {
      switch self {
      case .projectUnavailable:
        "请选择已登记的项目。"
      case .installationUnavailable:
        "请先在引擎设置中连接 DSH ACP。"
      case .permissionUnsupported:
        "DSH ACP 当前需要完整权限，请明确选择后再发送。"
      case .invalidInput:
        "消息或模型选择无效，消息最多为 32 KB。"
      }
    }
  }
}
