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
}
