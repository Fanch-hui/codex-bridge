import Foundation

/// Provider-neutral data, not a transcript or a provider's private session format.
public struct TaskHandoffItem: Codable, Equatable, Sendable {
  public let id: String
  public let sourceTaskID: String
  public let kind: String
  public let text: String

  public init(id: String, sourceTaskID: String, kind: String, text: String) {
    self.id = id
    self.sourceTaskID = sourceTaskID
    self.kind = kind
    self.text = text
  }
}

public struct TaskHandoffPacket: Codable, Equatable, Sendable {
  public static let currentSchemaVersion = 1
  public let schemaVersion: Int
  public let projectID: String
  public let sourceTaskID: String
  public let sourceProviderID: String
  public let sourceRevision: String
  public let capturedAt: String
  public let requirements: [TaskHandoffItem]
  public let outcomes: [TaskHandoffItem]
  public let evidence: [TaskHandoffItem]
  public let changedFiles: [String]
  public let warnings: [String]
  public let historyComplete: Bool

  public init(
    projectID: String, sourceTaskID: String, sourceProviderID: String,
    sourceRevision: String, capturedAt: String, requirements: [TaskHandoffItem],
    outcomes: [TaskHandoffItem], evidence: [TaskHandoffItem], changedFiles: [String],
    warnings: [String] = [], historyComplete: Bool = true,
    schemaVersion: Int = currentSchemaVersion
  ) {
    self.schemaVersion = schemaVersion
    self.projectID = projectID
    self.sourceTaskID = sourceTaskID
    self.sourceProviderID = sourceProviderID
    self.sourceRevision = sourceRevision
    self.capturedAt = capturedAt
    self.requirements = requirements
    self.outcomes = outcomes
    self.evidence = evidence
    self.changedFiles = changedFiles
    self.warnings = warnings
    self.historyComplete = historyComplete
  }
}

public struct TaskHandoffPreview: Codable, Equatable, Sendable {
  public let handoffID: String
  public let sourceTaskID: String
  public let providerID: String
  public let model: String
  public let permissionMode: String
  public let networkAllowed: Bool
  public let revision: String
  public let prompt: String
  public let additionalInstructions: String
  public let warnings: [String]
  public let ready: Bool
  public let estimatedTokens: Int
  public let contextWindowTokens: Int?
  public let phase: String
  public let targetTaskID: String?
  public let message: String?

  public init(
    handoffID: String, sourceTaskID: String, providerID: String, model: String,
    permissionMode: String, networkAllowed: Bool, revision: String, prompt: String,
    additionalInstructions: String, warnings: [String], ready: Bool, estimatedTokens: Int,
    contextWindowTokens: Int? = nil, phase: String = "prepared",
    targetTaskID: String? = nil, message: String? = nil
  ) {
    self.handoffID = handoffID
    self.sourceTaskID = sourceTaskID
    self.providerID = providerID
    self.model = model
    self.permissionMode = permissionMode
    self.networkAllowed = networkAllowed
    self.revision = revision
    self.prompt = prompt
    self.additionalInstructions = additionalInstructions
    self.warnings = warnings
    self.ready = ready
    self.estimatedTokens = estimatedTokens
    self.contextWindowTokens = contextWindowTokens
    self.phase = phase
    self.targetTaskID = targetTaskID
    self.message = message
  }
}

public enum TaskHandoffError: Error, LocalizedError, Equatable, Sendable {
  case rejected(String)

  public var errorDescription: String? {
    switch self {
    case .rejected(let message): return message
    }
  }
}
