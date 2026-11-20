import BridgeDomain
import Foundation

/// How a message to a child is delivered: `auto` steers a running task that supports it and
/// queues a continuation otherwise.
public enum SubagentDelivery: String, Codable, Sendable {
  case auto, queue, steer
}

public struct SubagentSendRequest: Equatable, Sendable {
  public var childID: String
  public var requestID: String
  public var prompt: String
  public var delivery: SubagentDelivery
  public var attachmentPaths: [String]
  public var repairConflict: Bool
  public var expectedTaskID: String?
  public var expectedRunID: String?
  public var createdAt: Date

  public init(
    childID: String, requestID: String, prompt: String, delivery: SubagentDelivery = .auto,
    attachmentPaths: [String] = [], repairConflict: Bool = false, expectedTaskID: String? = nil,
    expectedRunID: String? = nil, createdAt: Date
  ) {
    self.childID = childID
    self.requestID = requestID
    self.prompt = prompt
    self.delivery = delivery
    self.attachmentPaths = attachmentPaths
    self.repairConflict = repairConflict
    self.expectedTaskID = expectedTaskID
    self.expectedRunID = expectedRunID
    self.createdAt = createdAt
  }
}

/// The answer to a send whose request ID was already recorded.
public enum SubagentSendReplay: Equatable, Sendable {
  /// `{ accepted: true, state: 'checking' }`; `deliveryUnknown` adds `reason: 'delivery_unknown'`.
  case checking(deliveryUnknown: Bool)
  /// `{ accepted: true, taskID, delivery }`.
  case accepted(taskID: String, delivery: SubagentDelivery)
  /// `{ accepted: false, state, error? }` for a round that was withdrawn or failed.
  case refused(failed: Bool, error: String?)
  /// `{ accepted: true, queued: true, delivery: 'queue' }`.
  case queued
}

public enum SubagentSendAdmission: Equatable, Sendable {
  case replay(SubagentSendReplay)
  /// The same request is being handled by a live call; return that call's result.
  case joinInFlight
  /// Insert this `queued` continuation, then let the scheduler pick it up.
  case enqueue(SubagentRoundDraft)
  /// Insert this `dispatching` steer, then deliver the instruction to the running task. It is
  /// sent at most once.
  case steer(SubagentRoundDraft, taskID: String)
}

public enum SubagentStartAdmission: Equatable, Sendable {
  case create(SubagentRoundDraft)
  /// The identical request is still queued; reuse the stored round.
  case existing(SubagentRound)
}

public enum SubagentReceipt: Equatable, Sendable {
  case notFound
  case unknown(reason: String?, taskID: String?)
  case cancelled
  case failed(error: String?)
  case queued
  case accepted(taskID: String?)
}

extension SubagentRoundPlanner {
  /// Node `startExternal` idempotency: a delegation that was already recorded is only accepted
  /// again while it is still queued with the same prompt and fingerprint.
  public func admitStart(_ draft: SubagentRoundDraft) throws -> SubagentStartAdmission {
    guard let existing = round(draft.key.childID, draft.key.requestID) else {
      return .create(draft)
    }
    if draft.options.origin == .user || existing.options.origin == .user {
      guard draft.options.origin == .user, existing.options.origin == .user,
        existing.kind == .start, existing.projectID == draft.projectID,
        existing.parentSessionID == draft.parentSessionID,
        let prompt = draft.prompt, !existing.fingerprint.isEmpty
      else { throw SubagentRoundRejection.alreadyAdmitted }
      // Access is captured when the user starts the child. A later retry must validate the
      // original request even if the root's current permission has since changed.
      let fingerprint = SubagentRoundFingerprint.start(
        rootID: draft.key.rootID, childID: draft.key.childID,
        installationID: draft.installationID, requestID: draft.key.requestID,
        options: draft.options, access: existing.access, prompt: prompt,
        dependencies: draft.dependencies)
      guard existing.fingerprint == fingerprint else {
        throw SubagentRoundRejection.alreadyAdmitted
      }
      return .existing(existing)
    }
    guard existing.phase == .queued, existing.prompt == draft.prompt,
      existing.fingerprint.isEmpty || existing.fingerprint == draft.fingerprint
    else { throw SubagentRoundRejection.alreadyAdmitted }
    return .existing(existing)
  }

  /// Node `AgentInputs.send`. `inFlightFingerprint` is the fingerprint of a live call with the
  /// same child and request ID, if any.
  public func admitSend(_ request: SubagentSendRequest, inFlightFingerprint: String? = nil) throws
    -> SubagentSendAdmission
  {
    guard let binding = latest(of: request.childID, where: { !$0.isSteer }) else {
      throw SubagentRoundRejection.childNotFound
    }
    if request.repairConflict && request.delivery == .steer {
      throw SubagentRoundRejection.repairRequiresQueue
    }
    let fingerprint = SubagentRoundFingerprint.send(
      prompt: request.prompt, attachmentPaths: request.attachmentPaths,
      delivery: request.delivery, repairConflict: request.repairConflict,
      expectedTaskID: request.expectedTaskID, expectedRunID: request.expectedRunID)
    if let inFlightFingerprint {
      guard inFlightFingerprint == fingerprint else {
        throw SubagentRoundRejection.instructionConflict
      }
      return .joinInFlight
    }
    if let existing = round(request.childID, request.requestID) {
      let legacy = SubagentRoundFingerprint.legacySend(prompt: request.prompt)
      guard
        existing.fingerprint == fingerprint
          || (request.attachmentPaths.isEmpty && existing.fingerprint == legacy)
      else { throw SubagentRoundRejection.instructionConflict }
      return .replay(replay(existing))
    }
    try assertCurrent(
      childID: request.childID, expectedTaskID: request.expectedTaskID,
      expectedRunID: request.expectedRunID)
    return try admitNewSend(request, binding: binding, fingerprint: fingerprint)
  }

  private func replay(_ existing: SubagentRound) -> SubagentSendReplay {
    if existing.phase.isUnconfirmed || existing.phase == .deliveryUnknown {
      return .checking(deliveryUnknown: existing.phase == .deliveryUnknown)
    }
    if let taskID = existing.taskID {
      return .accepted(taskID: taskID, delivery: existing.isSteer ? .steer : .queue)
    }
    if existing.phase == .cancelled || existing.phase == .failed {
      return .refused(failed: existing.phase == .failed, error: existing.failureReason)
    }
    return .queued
  }

  /// Node `receipt`: what became of a recorded request. `isSending` is true while a live send of
  /// the same request is still being persisted.
  public func receipt(childID: String, requestID: String, isSending: Bool = false)
    -> SubagentReceipt
  {
    if isSending { return .unknown(reason: nil, taskID: nil) }
    guard let found = round(childID, requestID) else { return .notFound }
    switch found.phase {
    case .cancelled: return .cancelled
    case .failed: return .failed(error: found.failureReason)
    case .queued: return .queued
    case .dispatching, .unknown: return .unknown(reason: nil, taskID: nil)
    case .deliveryUnknown: return .unknown(reason: "delivery_unknown", taskID: found.taskID)
    case .running, .attached, .settled: return .accepted(taskID: found.taskID)
    }
  }
}
