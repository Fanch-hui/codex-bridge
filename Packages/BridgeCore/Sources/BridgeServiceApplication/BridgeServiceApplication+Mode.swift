import BridgeServiceCore

extension BridgeServiceApplication {
  public func requireNewWorkbenchTaskAdmission() async throws {
    try await workspaceGate.requireTaskAdmission()
  }

  public func beginWorkbenchPromptAdmission(sessionIDs: [String]) async throws -> String {
    try await workspaceGate.beginWorkbenchPromptAdmission(sessionIDs: sessionIDs)
  }

  public func endWorkbenchPromptAdmission(_ token: String) async {
    await workspaceGate.endWorkbenchPromptAdmission(token: token)
  }

  public func setLightweightAdmission(_ enabled: Bool) async {
    await workspaceGate.setLightweightMode(enabled)
  }

  public func beginLightweightTransition() async {
    await workspaceGate.beginLightweightTransition()
  }

  public func sealLightweightTransitionIfIdle() async throws -> Bool {
    guard await workspaceGate.sealLightweightTransition() else { return false }
    do {
      guard try await tasks.nonterminalTasks().isEmpty else {
        await workspaceGate.resumeLightweightTransition()
        return false
      }
      return true
    } catch {
      await workspaceGate.resumeLightweightTransition()
      throw error
    }
  }

  public func resumeLightweightTransition() async {
    await workspaceGate.resumeLightweightTransition()
  }
}
