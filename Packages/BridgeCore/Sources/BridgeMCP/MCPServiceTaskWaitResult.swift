import Foundation

public enum MCPServiceTaskWaitStatus: String, Codable, Sendable {
  case terminal
  case awaitingApproval = "awaiting_approval"
  case needsInput = "needs_input"
  case stillRunning = "still_running"
}

public struct MCPServiceTaskWaitResult: Codable, Sendable {
  public let task: MCPServiceTaskSnapshot
  public let waitStatus: MCPServiceTaskWaitStatus

  public init(task: MCPServiceTaskSnapshot, waitStatus: MCPServiceTaskWaitStatus) {
    self.task = task
    self.waitStatus = waitStatus
  }

  private enum CodingKeys: String, CodingKey {
    case task
    case waitStatus = "wait_status"
  }
}
