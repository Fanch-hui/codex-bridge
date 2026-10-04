import BridgeIPC
import BridgeMCP
import Foundation

public enum CodexPreferencesPatchError: Error, Equatable {
  case executionModelUnavailable
  case executionEffortUnavailable
  case executionEffortMissing
  case accessModeUnavailable
  case fastModeUnavailable

  public var message: String {
    switch self {
    case .executionModelUnavailable: "执行模型不可用。"
    case .executionEffortUnavailable: "执行推理强度不可用。"
    case .executionEffortMissing: "执行模型没有可用的推理强度。"
    case .accessModeUnavailable: "访问模式不可用。"
    case .fastModeUnavailable: "当前执行模型不支持快速模式。"
    }
  }
}

public enum CodexPreferencesPatch {
  public static func apply(
    to current: IPCModelPreferences,
    models: [MCPModelSummary],
    executionModel: String? = nil,
    executionEffort: String? = nil,
    accessMode: String? = nil,
    fastModeEnabled: Bool? = nil
  ) throws -> IPCModelPreferences {
    let modelID = try validated(
      executionModel ?? current.executionModel, maximumBytes: 256,
      error: .executionModelUnavailable)
    let model = models.first { $0.modelID == modelID }
    let changedModel = modelID != current.executionModel
    var effort = executionEffort ?? current.executionEffort
    if executionEffort == nil, changedModel, let model,
      !model.reasoningEfforts.contains(effort)
    {
      effort = model.defaultReasoningEffort ?? model.reasoningEfforts.first ?? effort
    }
    effort = try validated(effort, maximumBytes: 64, error: .executionEffortUnavailable)
    let access = accessMode ?? current.accessMode
    guard ["request-approval", "auto-review", "full-access"].contains(access) else {
      throw CodexPreferencesPatchError.accessModeUnavailable
    }
    let fast =
      fastModeEnabled
      ?? (changedModel && model?.supportsFastMode == false ? false : current.fastModeEnabled)
    if fastModeEnabled == true, model?.supportsFastMode == false {
      throw CodexPreferencesPatchError.fastModeUnavailable
    }
    return IPCModelPreferences(
      executionModel: modelID, executionEffort: effort,
      supervisorModel: current.supervisorModel, supervisorEffort: current.supervisorEffort,
      supervisorEnabled: current.supervisorEnabled, accessMode: access, fastModeEnabled: fast)
  }

  private static func validated(
    _ value: String, maximumBytes: Int, error: CodexPreferencesPatchError
  ) throws -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.utf8.count <= maximumBytes,
      trimmed.rangeOfCharacter(from: .controlCharacters) == nil
    else {
      throw error
    }
    return trimmed
  }
}

public struct CodexPreferencesSaveQueue: Sendable {
  public private(set) var active: IPCModelPreferences?
  public private(set) var pending: IPCModelPreferences?

  public init() {}

  public func editingValue(confirmed: IPCModelPreferences?) -> IPCModelPreferences? {
    pending ?? active ?? confirmed
  }

  public mutating func enqueue(_ value: IPCModelPreferences) {
    pending = value
  }

  public mutating func beginNext() -> IPCModelPreferences? {
    guard active == nil, let pending else { return nil }
    active = pending
    self.pending = nil
    return pending
  }

  public mutating func finish() { active = nil }
}
