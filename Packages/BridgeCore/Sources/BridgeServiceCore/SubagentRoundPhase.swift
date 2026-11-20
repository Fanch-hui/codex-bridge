import Foundation

/// Identity of one round: a delegation (`start`), a queued continuation (`send`) or a running-task
/// instruction (`steer`) of one child. `rootID` is the controller that owns the child; it is
/// deliberately not named after an engine session.
public struct SubagentRoundKey: Hashable, Codable, Sendable {
  public let rootID: String
  public let childID: String
  public let requestID: String

  public init(rootID: String, childID: String, requestID: String) {
    self.rootID = rootID
    self.childID = childID
    self.requestID = requestID
  }
}

/// `start` creates the child; `send` is a queued continuation that becomes a new task; `steer`
/// is an instruction delivered to the task that is already running and never creates a task.
public enum SubagentRoundKind: String, Codable, CaseIterable, Sendable {
  case start, send, steer
}

/// Where a round is in its life. This replaces the Node `admission` + `state` + `pendingOperation`
/// combination; the task state itself (running, completed, ...) is not mirrored here and is read
/// from the task snapshot instead.
///
/// ```
/// queued ──► dispatching ──► running ──► settled
///    │           │  ▲            (start / send)
///    │           │  └── unknown ──► running
///    │           ├────► attached            (steer)
///    │           └────► deliveryUnknown     (steer, from dispatching or unknown)
///    ├──► cancelled   (also from dispatching before anything was sent; not steer)
///    └──► failed      (also from dispatching and unknown)
/// ```
///
/// Allowed transitions (a phase may always be rewritten to itself to update flags):
/// - `queued` → `dispatching`, `cancelled`, `failed`
/// - `dispatching` → `running` | `unknown` | `cancelled` | `failed`; a steer goes to `attached` |
///   `unknown` | `deliveryUnknown` | `failed` instead
/// - `unknown` → `running` | `failed`; a steer goes to `attached` | `deliveryUnknown` | `failed`
/// - `running` → `settled`
/// - `deliveryUnknown`, `attached`, `settled`, `cancelled` and `failed` have no successor.
public enum SubagentRoundPhase: String, Codable, CaseIterable, Sendable {
  /// Recorded and waiting for dependencies, the previous round, capacity or a write lease. Holds
  /// the prompt. Node: `admission == waiting` with a pending operation.
  case queued
  /// Admitted; the dispatch is about to be or is being made. The prompt is still held. A
  /// `dispatching` row found after a restart means the outcome is unknown and must be probed.
  /// Node: `dispatching`.
  case dispatching
  /// The dispatch ended without a definite outcome and must be probed by request ID (a steer is
  /// never resent). `dispatchError` keeps the answer for the failure notice. Node: `unknown`.
  case unknown
  /// Steer only: the provider may or may not have received the instruction. It is never resent and
  /// has no exit. Node: `delivery_unknown`.
  case deliveryUnknown = "delivery_unknown"
  /// The task exists (`taskID` is set) and has not been observed to finish. Node: `accepted` while
  /// the task state is not terminal.
  case running
  /// Steer only: the instruction was attached to the running task. Node: `attached`.
  case attached
  /// The task finished. The result may still have to be delivered (`delivered`). Node: `accepted`
  /// with a terminal state, or `settled`.
  case settled
  /// Never dispatched and withdrawn: cancelled by the user, by a stop, or rejected during
  /// admission. Node: `cancelled` with state `cancelled`.
  case cancelled
  /// Never dispatched (or confirmed absent after an uncertain dispatch) because of an error. Keeps
  /// `failureReason`. Node: `cancelled` with state `failed`.
  case failed

  /// Phases a row of this kind may be stored in.
  public static func storable(for kind: SubagentRoundKind) -> Set<SubagentRoundPhase> {
    switch kind {
    case .steer: [.dispatching, .unknown, .deliveryUnknown, .attached, .failed]
    case .start, .send: [.queued, .dispatching, .unknown, .running, .settled, .cancelled, .failed]
    }
  }

  /// Phases that still hold the prompt.
  public var holdsPrompt: Bool { self == .queued || self == .dispatching || self == .unknown }

  /// Phases in which the dispatch outcome is not known yet (Node: `dispatching` and `unknown`).
  public var isUnconfirmed: Bool { self == .dispatching || self == .unknown }

  public func canTransition(to next: SubagentRoundPhase, kind: SubagentRoundKind) -> Bool {
    if self == next { return true }
    let isSteer = kind == .steer
    switch self {
    case .queued:
      return [.dispatching, .cancelled, .failed].contains(next)
    case .dispatching:
      return isSteer
        ? [.attached, .unknown, .deliveryUnknown, .failed].contains(next)
        : [.running, .unknown, .cancelled, .failed].contains(next)
    case .unknown:
      return isSteer
        ? [.attached, .deliveryUnknown, .failed].contains(next)
        : [.running, .failed].contains(next)
    case .running:
      return next == .settled
    case .deliveryUnknown, .attached, .settled, .cancelled, .failed:
      return false
    }
  }
}

/// Why a round ended in `failed`; selects the notice text delivered to the controller.
public enum SubagentFailureOrigin: String, Codable, Sendable {
  /// A dependency or the previous round ended badly; `failureReason` is the full message.
  case dependency
  /// The dispatch was rejected or never reached Bridge; `failureReason` is Bridge's answer, if any.
  case dispatch
  /// A steer was rejected before it was sent; `failureReason` is the error message.
  case input
}

public enum SubagentWorkspaceMode: String, Codable, Sendable {
  case readOnly = "read-only"
  case shared
  case isolated
}

/// `task`: the whole task holds the write lease. `tool`: Bridge gates each writing tool call.
public enum SubagentWriteScope: String, Codable, Sendable {
  case task, tool
}

public enum SubagentRoundAccess: String, Codable, Sendable {
  case readOnly = "read-only"
}

public struct SubagentRoundDependency: Hashable, Codable, Sendable {
  public let childID: String
  public let requestID: String

  public init(childID: String, requestID: String) {
    self.childID = childID
    self.requestID = requestID
  }
}

/// Who asked for a round. A `user` round was handed to the agent directly by the user; its result is
/// context for the model, not something the model asked for, so it must not start a model turn.
public enum SubagentRoundOrigin: String, Codable, Sendable {
  case model, user
}

/// Dispatch parameters that outlive the prompt. `label` names the child in the controller's
/// subagent catalog.
public struct SubagentRoundOptions: Equatable, Codable, Sendable {
  public var model: String?
  public var effort: String?
  public var attachmentPaths: [String]
  public var label: String?
  /// Stored only for a `user` round, so every record written before the field existed (and every
  /// delegation by the model) keeps its bytes and reads back as `model`.
  public var origin: SubagentRoundOrigin

  public init(
    model: String? = nil, effort: String? = nil, attachmentPaths: [String] = [],
    label: String? = nil, origin: SubagentRoundOrigin = .model
  ) {
    self.model = model
    self.effort = effort
    self.attachmentPaths = attachmentPaths
    self.label = label
    self.origin = origin
  }

  private enum CodingKeys: String, CodingKey {
    case model, effort, attachmentPaths, label, origin
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    model = try container.decodeIfPresent(String.self, forKey: .model)
    effort = try container.decodeIfPresent(String.self, forKey: .effort)
    attachmentPaths = try container.decode([String].self, forKey: .attachmentPaths)
    label = try container.decodeIfPresent(String.self, forKey: .label)
    origin = try container.decodeIfPresent(SubagentRoundOrigin.self, forKey: .origin) ?? .model
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encodeIfPresent(model, forKey: .model)
    try container.encodeIfPresent(effort, forKey: .effort)
    try container.encode(attachmentPaths, forKey: .attachmentPaths)
    try container.encodeIfPresent(label, forKey: .label)
    if origin != .model { try container.encode(origin, forKey: .origin) }
  }
}
