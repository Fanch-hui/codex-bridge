import BridgeMCP
import Foundation

public enum TaskRetrySubmission {
  public static func modelOverride(for task: MCPServiceTaskSnapshot) -> Bool {
    guard let model = task.executionModel?.trimmingCharacters(in: .whitespacesAndNewlines),
      !model.isEmpty
    else {
      return false
    }
    return model != "provider-default"
  }

  public static func effort(for task: MCPServiceTaskSnapshot) -> String? {
    guard let effort = task.executionEffort?.trimmingCharacters(in: .whitespacesAndNewlines),
      !effort.isEmpty, effort != "provider-default"
    else {
      return nil
    }
    return effort
  }
}
