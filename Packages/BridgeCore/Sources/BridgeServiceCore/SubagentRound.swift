import BridgeDomain
import Foundation

/// A round as it is about to be inserted. The store assigns the ordinal and the update time.
public struct SubagentRoundDraft: Equatable, Sendable {
  public var key: SubagentRoundKey
  public var projectID: ProjectID
  public var parentSessionID: String
  public var installationID: String
  public var kind: SubagentRoundKind
  public var phase: SubagentRoundPhase
  /// Opaque request identity; equal fingerprints mean the same request (see
  /// `SubagentRoundFingerprint`).
  public var fingerprint: String
  /// Held while the round is `queued`, `dispatching` or `unknown`; never for a steer.
  public var prompt: String?
  public var options: SubagentRoundOptions
  public var access: SubagentRoundAccess?
  public var repairConflict: Bool
  public var dependencies: [SubagentRoundDependency]
  public var previousRequestID: String?
  public var previousTaskID: String?
  public var previousRunID: String?
  public var requestedAfterTerminal: Bool
  public var taskID: String?
  public var waitingReason: String?
  public var failureReason: String?
  public var failureOrigin: SubagentFailureOrigin?
  public var dispatchError: String?
  public var deliveryRequired: Bool
  public var delivered: Bool
  public var workspaceMode: SubagentWorkspaceMode?
  public var writeScope: SubagentWriteScope?
  public var reservationHeld: Bool
  public var leaseHeld: Bool
  /// When the child was created; continuations carry the creation time of the first round.
  public var childCreatedAt: Date
  public var createdAt: Date
  /// Only for rounds imported finished from an older orchestrator, which stamped their own
  /// settle time; the retention window then continues where it was.
  public var settledAt: Date?

  public init(
    key: SubagentRoundKey, projectID: ProjectID, parentSessionID: String, installationID: String,
    kind: SubagentRoundKind, phase: SubagentRoundPhase? = nil, fingerprint: String,
    prompt: String? = nil, options: SubagentRoundOptions = .init(),
    access: SubagentRoundAccess? = nil, repairConflict: Bool = false,
    dependencies: [SubagentRoundDependency] = [], previousRequestID: String? = nil,
    previousTaskID: String? = nil, previousRunID: String? = nil,
    requestedAfterTerminal: Bool = false, taskID: String? = nil, waitingReason: String? = nil,
    failureReason: String? = nil, failureOrigin: SubagentFailureOrigin? = nil,
    dispatchError: String? = nil, deliveryRequired: Bool? = nil, delivered: Bool = false,
    workspaceMode: SubagentWorkspaceMode? = nil, writeScope: SubagentWriteScope? = nil,
    reservationHeld: Bool = false, leaseHeld: Bool = false, childCreatedAt: Date? = nil,
    createdAt: Date, settledAt: Date? = nil
  ) {
    self.key = key
    self.projectID = projectID
    self.parentSessionID = parentSessionID
    self.installationID = installationID
    self.kind = kind
    self.phase = phase ?? (kind == .steer ? .dispatching : .queued)
    self.fingerprint = fingerprint
    self.prompt = prompt
    self.options = options
    self.access = access
    self.repairConflict = repairConflict
    self.dependencies = dependencies
    self.previousRequestID = previousRequestID
    self.previousTaskID = previousTaskID
    self.previousRunID = previousRunID
    self.requestedAfterTerminal = requestedAfterTerminal
    self.taskID = taskID
    self.waitingReason = waitingReason
    self.failureReason = failureReason
    self.failureOrigin = failureOrigin
    self.dispatchError = dispatchError
    self.deliveryRequired = deliveryRequired ?? (kind != .steer)
    self.delivered = delivered
    self.workspaceMode = workspaceMode
    self.writeScope = writeScope
    self.reservationHeld = reservationHeld
    self.leaseHeld = leaseHeld
    self.childCreatedAt = childCreatedAt ?? createdAt
    self.createdAt = createdAt
    self.settledAt = settledAt
  }
}

/// One stored round. Identity and request fields are fixed once inserted; the `var` fields are
/// the ones the scheduler updates through `SimpleServiceStore.updateSubagentRound`.
public struct SubagentRound: Equatable, Sendable {
  public let key: SubagentRoundKey
  public let projectID: ProjectID
  /// Insertion order across the whole ledger. Node relied on array order for "latest round of a
  /// child", "previous round" and the queue order; this column replaces it.
  public let ordinal: Int64
  public let parentSessionID: String
  public let installationID: String
  public let kind: SubagentRoundKind
  public let fingerprint: String
  public let options: SubagentRoundOptions
  public let access: SubagentRoundAccess?
  public let repairConflict: Bool
  public let dependencies: [SubagentRoundDependency]
  public let previousRequestID: String?
  public let previousTaskID: String?
  public let previousRunID: String?
  public let requestedAfterTerminal: Bool
  public let deliveryRequired: Bool
  public let childCreatedAt: Date
  public let createdAt: Date

  public internal(set) var phase: SubagentRoundPhase
  public internal(set) var prompt: String?
  public var taskID: String?
  /// Why a `queued` round is waiting: a workspace status such as `conflict`, or `capacity`.
  public var waitingReason: String?
  public var failureReason: String?
  public var failureOrigin: SubagentFailureOrigin?
  /// Bridge's answer when a dispatch ended `unknown`; becomes the failure reason if the request
  /// turns out never to have been dispatched.
  public var dispatchError: String?
  public var workspaceMode: SubagentWorkspaceMode?
  public var writeScope: SubagentWriteScope?
  /// A workspace capacity reservation is held (Node: `reservationHeld`).
  public var reservationHeld: Bool
  /// The task-long write lease is held for this round.
  public var leaseHeld: Bool
  public internal(set) var delivered: Bool
  /// Stamped by the retention pass when the round is finished; cleared when it is not.
  public internal(set) var settledAt: Date?
  public internal(set) var updatedAt: Date

  public var isSteer: Bool { kind == .steer }

  public init(
    draft: SubagentRoundDraft, ordinal: Int64, updatedAt: Date? = nil, settledAt: Date? = nil
  ) {
    key = draft.key
    projectID = draft.projectID
    self.ordinal = ordinal
    parentSessionID = draft.parentSessionID
    installationID = draft.installationID
    kind = draft.kind
    fingerprint = draft.fingerprint
    options = draft.options
    access = draft.access
    repairConflict = draft.repairConflict
    dependencies = draft.dependencies
    previousRequestID = draft.previousRequestID
    previousTaskID = draft.previousTaskID
    previousRunID = draft.previousRunID
    requestedAfterTerminal = draft.requestedAfterTerminal
    deliveryRequired = draft.deliveryRequired
    childCreatedAt = draft.childCreatedAt
    createdAt = draft.createdAt
    phase = draft.phase
    prompt = draft.prompt
    taskID = draft.taskID
    waitingReason = draft.waitingReason
    failureReason = draft.failureReason
    failureOrigin = draft.failureOrigin
    dispatchError = draft.dispatchError
    workspaceMode = draft.workspaceMode
    writeScope = draft.writeScope
    reservationHeld = draft.reservationHeld
    leaseHeld = draft.leaseHeld
    delivered = draft.delivered
    self.settledAt = settledAt ?? draft.settledAt
    self.updatedAt = updatedAt ?? draft.createdAt
  }
}
