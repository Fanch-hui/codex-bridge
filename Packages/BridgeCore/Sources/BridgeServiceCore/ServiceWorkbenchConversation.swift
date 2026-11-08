import Foundation

public struct ServiceWorkbenchConversation: Codable, Equatable, Sendable {
  public let logicalSessionID: String
  public let nativeSessionID: String
  public let projectID: String?
  public let createdAt: Date
  public let updatedAt: Date
}

public struct ServiceWorkbenchConversationCursor: Equatable, Sendable {
  public let updatedAt: Date
  public let logicalSessionID: String

  public init(updatedAt: Date, logicalSessionID: String) {
    self.updatedAt = updatedAt
    self.logicalSessionID = logicalSessionID
  }
}

public struct ServiceWorkbenchSegment: Codable, Equatable, Sendable {
  public let logicalSessionID: String
  public let nativeSessionID: String
  public let ordinal: Int64
  public let projectID: String?
  public let createdAt: Date
}

public enum ServiceWorkbenchBindingPhase: String, Codable, Sendable {
  case prepared, oldStopped, segmentCreated, continuationEnqueued, committed, cancelled
}

public struct ServiceWorkbenchBinding: Codable, Equatable, Sendable {
  public let logicalSessionID: String
  public let sourceNativeSessionID: String
  public let targetNativeSessionID: String
  public let projectID: String
  public let requestID: String
  public let toolCallID: String
  public let boundarySeq: Int64?
  public let phase: ServiceWorkbenchBindingPhase
  public let version: Int64
  public let createdAt: Date
  public let updatedAt: Date
}

public struct ServiceWorkbenchPendingInteraction: Codable, Equatable, Sendable {
  public let logicalSessionID: String
  public let interactionID: String
  public let nativeSessionID: String
  public let kind: String
  public let eventSeq: Int64
  public let updatedAt: Date

  public init(
    logicalSessionID: String, interactionID: String, nativeSessionID: String,
    kind: String, eventSeq: Int64, updatedAt: Date = Date()
  ) {
    self.logicalSessionID = logicalSessionID
    self.interactionID = interactionID
    self.nativeSessionID = nativeSessionID
    self.kind = kind
    self.eventSeq = eventSeq
    self.updatedAt = updatedAt
  }
}
