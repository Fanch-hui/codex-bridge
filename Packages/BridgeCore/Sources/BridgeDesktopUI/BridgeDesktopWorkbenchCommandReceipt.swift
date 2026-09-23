import BridgeServiceAppCore
import Foundation

public struct BridgeDesktopWorkbenchCommandReceipt: Codable, Equatable, Sendable {
  public let receiptID: String
  public let requestID: String
  public let command: String
  public let taskID: String?
  public let input: String?
  public let accepted: Bool
  public let message: String?
  public let handoff: WorkbenchHandoffPreview?

  public init(
    requestID: String,
    command: String,
    taskID: String?,
    input: String?,
    accepted: Bool,
    message: String? = nil,
    handoff: WorkbenchHandoffPreview? = nil,
    receiptID: String = UUID().uuidString
  ) {
    self.receiptID = receiptID
    self.requestID = requestID
    self.command = command
    self.taskID = taskID
    self.input = input
    self.accepted = accepted
    self.message = message
    self.handoff = handoff
  }
}

public enum BridgeDesktopWorkbenchCommandAck {
  public static func receipt(
    requestID: String,
    command: String,
    taskID: String?,
    input: String?,
    accepted: Bool,
    message: String? = nil,
    handoff: WorkbenchHandoffPreview? = nil
  ) -> BridgeDesktopWorkbenchCommandReceipt {
    BridgeDesktopWorkbenchCommandReceipt(
      requestID: requestID,
      command: command,
      taskID: taskID,
      input: input,
      accepted: accepted,
      message: message,
      handoff: handoff
    )
  }
}
