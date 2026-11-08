import Foundation

public enum ServiceWorkbenchOperationPhase: String, Codable, Sendable {
  case recorded, dispatching, accepted, unknown, completed, failed, cancelled

  public var isTerminal: Bool {
    self == .completed || self == .failed || self == .cancelled
  }
}

public struct ServiceWorkbenchOperationDraft: Codable, Equatable, Sendable {
  public let operationID: String
  public let kind: String
  public let sessionID: String?
  public let childID: String?
  public let projectID: String?
  public let targetID: String?
  public let requestID: String
  public let inputJSON: String

  public init(
    operationID: String, kind: String, sessionID: String? = nil, childID: String? = nil,
    projectID: String? = nil, targetID: String? = nil, requestID: String? = nil,
    inputJSON: String
  ) {
    self.operationID = operationID
    self.kind = kind
    self.sessionID = sessionID
    self.childID = childID
    self.projectID = projectID
    self.targetID = targetID
    self.requestID = requestID ?? operationID
    self.inputJSON = inputJSON
  }
}

public struct ServiceWorkbenchOperation: Codable, Equatable, Sendable {
  public let draft: ServiceWorkbenchOperationDraft
  public let generation: Int64
  public let inputDigest: String
  public let phase: ServiceWorkbenchOperationPhase
  public let resultTargetID: String?
  public let resultJSON: String?
  public let cancelled: Bool
  public let version: Int64
  public let createdAt: Date
  public let updatedAt: Date

  init(
    draft: ServiceWorkbenchOperationDraft, generation: Int64, inputDigest: String,
    phase: ServiceWorkbenchOperationPhase, resultTargetID: String?, resultJSON: String?,
    cancelled: Bool, version: Int64, createdAt: Date, updatedAt: Date
  ) {
    self.draft = draft
    self.generation = generation
    self.inputDigest = inputDigest
    self.phase = phase
    self.resultTargetID = resultTargetID
    self.resultJSON = resultJSON
    self.cancelled = cancelled
    self.version = version
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }

  private enum CodingKeys: String, CodingKey {
    case operationID, kind, sessionID, childID, projectID, targetID, requestID, inputJSON
    case generation, inputDigest, phase, resultTargetID, resultJSON, cancelled, version, createdAt,
      updatedAt
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    draft = try ServiceWorkbenchOperationDraft(
      operationID: values.decode(String.self, forKey: .operationID),
      kind: values.decode(String.self, forKey: .kind),
      sessionID: values.decodeIfPresent(String.self, forKey: .sessionID),
      childID: values.decodeIfPresent(String.self, forKey: .childID),
      projectID: values.decodeIfPresent(String.self, forKey: .projectID),
      targetID: values.decodeIfPresent(String.self, forKey: .targetID),
      requestID: values.decode(String.self, forKey: .requestID),
      inputJSON: values.decode(String.self, forKey: .inputJSON))
    generation = try values.decode(Int64.self, forKey: .generation)
    inputDigest = try values.decode(String.self, forKey: .inputDigest)
    phase = try values.decode(ServiceWorkbenchOperationPhase.self, forKey: .phase)
    resultTargetID = try values.decodeIfPresent(String.self, forKey: .resultTargetID)
    resultJSON = try values.decodeIfPresent(String.self, forKey: .resultJSON)
    cancelled = try values.decode(Bool.self, forKey: .cancelled)
    version = try values.decode(Int64.self, forKey: .version)
    createdAt = Date(timeIntervalSince1970: try values.decode(Double.self, forKey: .createdAt))
    updatedAt = Date(timeIntervalSince1970: try values.decode(Double.self, forKey: .updatedAt))
  }

  public func encode(to encoder: Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(draft.operationID, forKey: .operationID)
    try values.encode(draft.kind, forKey: .kind)
    try values.encodeIfPresent(draft.sessionID, forKey: .sessionID)
    try values.encodeIfPresent(draft.childID, forKey: .childID)
    try values.encodeIfPresent(draft.projectID, forKey: .projectID)
    try values.encodeIfPresent(draft.targetID, forKey: .targetID)
    try values.encode(draft.requestID, forKey: .requestID)
    try values.encode(draft.inputJSON, forKey: .inputJSON)
    try values.encode(generation, forKey: .generation)
    try values.encode(inputDigest, forKey: .inputDigest)
    try values.encode(phase, forKey: .phase)
    try values.encodeIfPresent(resultTargetID, forKey: .resultTargetID)
    try values.encodeIfPresent(resultJSON, forKey: .resultJSON)
    try values.encode(cancelled, forKey: .cancelled)
    try values.encode(version, forKey: .version)
    try values.encode(createdAt.timeIntervalSince1970, forKey: .createdAt)
    try values.encode(updatedAt.timeIntervalSince1970, forKey: .updatedAt)
  }
}

public struct ServiceWorkbenchOperationRegistration: Equatable, Sendable {
  public let operation: ServiceWorkbenchOperation
  public let created: Bool

  public init(operation: ServiceWorkbenchOperation, created: Bool) {
    self.operation = operation
    self.created = created
  }
}

public struct ServiceWorkbenchGeneration: Equatable, Sendable {
  public let sessionID: String
  public let generation: Int64
  public let closed: Bool
}
