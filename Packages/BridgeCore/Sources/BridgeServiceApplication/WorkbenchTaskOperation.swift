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
