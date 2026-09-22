import BridgeDomain
import Foundation

public typealias MCPTaskHandoffPreview = TaskHandoffPreview

public struct MCPTaskHandoffRequest: Codable, Equatable, Sendable {
  public enum Action: String, Codable, Sendable { case prepare, submit, status }
  public let action: Action
  public let sourceTaskID: String
  public let providerID: String
  public let handoffID: String
  public let additionalInstructions: String
  public let expectedRevision: String?

  public init(
    action: Action, sourceTaskID: String, providerID: String, handoffID: String,
    additionalInstructions: String = "", expectedRevision: String? = nil
  ) {
    self.action = action
    self.sourceTaskID = sourceTaskID
    self.providerID = providerID
    self.handoffID = handoffID
    self.additionalInstructions = additionalInstructions
    self.expectedRevision = expectedRevision
  }
}
