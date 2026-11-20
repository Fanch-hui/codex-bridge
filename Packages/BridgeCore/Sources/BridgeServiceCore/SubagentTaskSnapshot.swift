import Foundation

/// A task state as Bridge reports it (`awaiting_local_approval`, `running`, `completed`, ...), plus
/// `created` for a round without a task and `cancelled` for a withdrawn one. Open-ended on purpose:
/// the planner only distinguishes terminal and failed states.
public struct SubagentTaskState: RawRepresentable, Hashable, ExpressibleByStringLiteral, Sendable {
  public let rawValue: String
  public init(rawValue: String) { self.rawValue = rawValue }
  public init(stringLiteral value: String) { rawValue = value }

  public static let created: SubagentTaskState = "created"
  public static let running: SubagentTaskState = "running"
  public static let completed: SubagentTaskState = "completed"
  public static let failed: SubagentTaskState = "failed"
  public static let interrupted: SubagentTaskState = "interrupted"
  public static let cancelled: SubagentTaskState = "cancelled"

  /// Node `terminal`: completed, failed, interrupted, cancelled.
  public var isTerminal: Bool { self == .completed || isFailure }
  /// Node `failed`: a terminal state other than success.
  public var isFailure: Bool { self == .failed || self == .interrupted || self == .cancelled }
}

/// A workspace merge status: `pending`, `conflict`, `merged`, `retained`, `failed`,
/// `validation_required`, `recovery_required`.
public struct SubagentWorkspaceStatus: RawRepresentable, Hashable, ExpressibleByStringLiteral,
  Sendable
{
  public let rawValue: String
  public init(rawValue: String) { self.rawValue = rawValue }
  public init(stringLiteral value: String) { rawValue = value }

  public static let pending: SubagentWorkspaceStatus = "pending"
  public static let conflict: SubagentWorkspaceStatus = "conflict"
  public static let merged: SubagentWorkspaceStatus = "merged"
  public static let retained: SubagentWorkspaceStatus = "retained"
  public static let failed: SubagentWorkspaceStatus = "failed"
}

/// What the planner needs to know about one Bridge task: Node's `get` snapshot, reduced to the
/// fields that influence a decision. The scheduler builds it from the task and workspace records.
public struct SubagentTaskSnapshot: Equatable, Sendable {
  public var taskID: String
  public var state: SubagentTaskState
  public var runID: String?
  public var workspaceMode: SubagentWorkspaceMode?
  public var workspaceStatus: SubagentWorkspaceStatus?
  /// `capabilities.canSteer`; only an explicit `true` counts.
  public var canSteer: Bool?
  /// `capabilities.canContinue`; only an explicit `false` forbids a continuation.
  public var canContinue: Bool?
  /// `capabilities.supportsContinue`; only an explicit `false` forbids a continuation.
  public var supportsContinue: Bool?
  /// Node: `snapshot.canRepairWithAgent === true || snapshot.capabilities.canRepairWithAgent === true`.
  public var canRepairWithAgent: Bool

  public init(
    taskID: String, state: SubagentTaskState, runID: String? = nil,
    workspaceMode: SubagentWorkspaceMode? = nil, workspaceStatus: SubagentWorkspaceStatus? = nil,
    canSteer: Bool? = nil, canContinue: Bool? = nil, supportsContinue: Bool? = nil,
    canRepairWithAgent: Bool = false
  ) {
    self.taskID = taskID
    self.state = state
    self.runID = runID
    self.workspaceMode = workspaceMode
    self.workspaceStatus = workspaceStatus
    self.canSteer = canSteer
    self.canContinue = canContinue
    self.supportsContinue = supportsContinue
    self.canRepairWithAgent = canRepairWithAgent
  }
}
