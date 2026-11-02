import Foundation

extension BridgeServiceApplication {
  public func beginUnscopedWorkbenchExecution(sessionID: String) async throws -> String {
    if let token = unscopedWorkbenchExecutions[sessionID] { return token }
    let token = try await workspaceGate.beginTaskAdmission()
    if let existing = unscopedWorkbenchExecutions[sessionID] {
      await workspaceGate.endTaskAdmission(token: token)
      return existing
    }
    unscopedWorkbenchExecutions[sessionID] = token
    return token
  }

  public func finishUnscopedWorkbenchExecution(sessionID: String) async {
    guard let token = unscopedWorkbenchExecutions.removeValue(forKey: sessionID) else { return }
    await workspaceGate.endTaskAdmission(token: token)
  }

  public func activeUnscopedWorkbenchSessionIDs() -> [String] {
    unscopedWorkbenchExecutions.keys.sorted()
  }

  public func finishAllUnscopedWorkbenchExecutions() async {
    for id in Array(unscopedWorkbenchExecutions.keys) {
      await finishUnscopedWorkbenchExecution(sessionID: id)
    }
  }
}
