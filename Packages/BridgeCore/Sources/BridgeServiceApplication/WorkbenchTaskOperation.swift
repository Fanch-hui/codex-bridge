import BridgeAgentCore
import BridgeMCP
import BridgeSecurity
import BridgeServiceCore
import Foundation

public struct WorkbenchTaskOperationNotDispatched: Error, LocalizedError, Sendable {
  public let causeMessage: String

  public var errorDescription: String? { causeMessage }

  public init(cause: any Error) {
    let description = (cause as? any LocalizedError)?.errorDescription ?? String(describing: cause)
    causeMessage = OutboundContentSecurity.redacted(description, maximumUTF8Bytes: 1_024)
  }
}

struct WorkbenchTaskOperationInput: Codable, Equatable, Sendable {
  let taskID: String
  let input: String?
  let mode: MCPTaskSteerMode?
  let queueIfBusy: Bool?
  let attachmentPaths: [String]?
  let skillNames: [String]?
  let providerID: String?
  let handoffID: String?
  let revision: String?
  /// Optional model, effort and task mode for a session continuation; absent keeps the original.
  let executionSelection: WorkbenchTaskExecutionSelection?
}

struct WorkbenchTaskExecutionSelection: Codable, Equatable, Sendable {
  let modelID: String?
  let effort: String?
  let permissionMode: String

  func validated() throws -> Self {
    guard ServicePermissionMode(rawValue: permissionMode) != nil else {
      throw BridgeMCPQueryError.contractRejected
    }
    return Self(
      modelID: try Self.value(modelID, maximumBytes: 256),
      effort: try Self.value(effort, maximumBytes: 64), permissionMode: permissionMode)
  }

  private static func value(_ value: String?, maximumBytes: Int) throws -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.utf8.count <= maximumBytes,
      trimmed.rangeOfCharacter(from: .controlCharacters) == nil
    else { throw BridgeMCPQueryError.contractRejected }
    return trimmed.isEmpty || trimmed == serviceDefaultProviderExecutionModel ? nil : trimmed
  }
}

/// The model, effort and task mode a workbench continuation runs with.
struct WorkbenchResumeExecution: Equatable, Sendable {
  let executionModel: String
  let executionEffort: String
  let permissionMode: ServicePermissionMode
  /// False when the selection names no effort for a different model: the service then
  /// resolves the effort from the Agent defaults, and any resolved value is accepted.
  let fixesEffort: Bool

  init(binding: WorkbenchTaskOperationBinding, request: WorkbenchTaskOperationInput) {
    guard let selection = try? request.executionSelection?.validated(),
      let permission = ServicePermissionMode(rawValue: selection.permissionMode)
    else {
      executionModel = binding.executionModel
      executionEffort = binding.executionEffort
      permissionMode = binding.permissionMode
      fixesEffort = true
      return
    }
    executionModel = selection.modelID ?? serviceDefaultProviderExecutionModel
    permissionMode = permission
    if let effort = selection.effort {
      executionEffort = effort
      fixesEffort = true
    } else if executionModel == binding.executionModel {
      // An unchanged model without an explicit effort keeps the session's effort; the
      // composer omits the effort while the model catalog is still loading.
      executionEffort = binding.executionEffort
      fixesEffort = true
    } else {
      executionEffort = serviceDefaultProviderExecutionEffort
      fixesEffort = false
    }
  }

  var submittedModel: String? {
    executionModel == serviceDefaultProviderExecutionModel ? nil : executionModel
  }
  var submittedEffort: String? {
    executionEffort == serviceDefaultProviderExecutionEffort ? nil : executionEffort
  }

  func accepts(model: String, effort: String, permission: ServicePermissionMode) -> Bool {
    model == executionModel && permission == permissionMode
      && (!fixesEffort || effort == executionEffort)
  }
}

struct WorkbenchTaskOperationBinding: Codable, Equatable, Sendable {
  let taskID: String
  let projectID: String
  let providerID: String
  let installationID: String?
  let sessionID: String?
  let controlID: String?
  let executionModel: String
  let executionEffort: String
  let permissionMode: ServicePermissionMode
  let accessMode: ServiceAccessMode
  let fastMode: Bool
  let projectRoot: ServiceRootIdentity
  let artifactDigest: String?
  let runtimeMode: DeepSeekHarnessConnectionMode?
  let runtimeProfileID: String?
  let attachments: [AgentImageAttachment]
  let handoffFingerprint: String?
  let handoffSourceRevision: String?
}

struct PreparedWorkbenchTaskOperation: Codable, Equatable, Sendable {
  let request: WorkbenchTaskOperationInput
  let binding: WorkbenchTaskOperationBinding
}

struct WorkbenchTaskOperationReceipt: Codable, Equatable, Sendable {
  let accepted: Bool
  let taskID: String?
  let status: String
  let handoff: MCPTaskHandoffPreview?

  init(taskID: String?, status: String, handoff: MCPTaskHandoffPreview? = nil) {
    self.accepted = true
    self.taskID = taskID
    self.status = status
    self.handoff = handoff
  }
}

enum WorkbenchTaskOperationCodec {
  static func encode<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return String(decoding: try encoder.encode(value), as: UTF8.self)
  }

  static func decode<T: Decodable>(_ type: T.Type, _ inputJSON: String) throws -> T {
    guard inputJSON.utf8.count <= 2 * 1_024 * 1_024,
      let data = inputJSON.data(using: .utf8)
    else { throw BridgeMCPQueryError.contractRejected }
    do { return try JSONDecoder().decode(type, from: data) } catch {
      throw BridgeMCPQueryError.contractRejected
    }
  }
}

struct WorkbenchInstallationArtifact: Encodable {
  let role: String
  let identity: ServiceAgentFileIdentity
}
