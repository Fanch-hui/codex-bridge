import BridgeServiceCore
import Foundation

extension BridgeServiceApplication {
  public func beginWorkbenchMaintenance(operationID: String) async throws -> Bool {
    guard !operationID.isEmpty, operationID.utf8.count <= 256,
      operationID.rangeOfCharacter(from: .controlCharacters) == nil
    else { throw ServiceStoreError.invalidArgument("workbench.maintenance") }
    if workbenchMaintenanceAdmissions[operationID] != nil { return false }
    let token = try await workspaceGate.beginTaskAdmission()
    if workbenchMaintenanceAdmissions[operationID] != nil {
      await workspaceGate.endTaskAdmission(token: token)
      return false
    }
    workbenchMaintenanceAdmissions[operationID] = token
    return true
  }

  public func finishWorkbenchMaintenance(operationID: String) async {
    guard let token = workbenchMaintenanceAdmissions.removeValue(forKey: operationID) else {
      return
    }
    await workspaceGate.endTaskAdmission(token: token)
  }

  public func activeWorkbenchMaintenanceOperationIDs() -> [String] {
    workbenchMaintenanceAdmissions.keys.sorted()
  }

  public func finishAllWorkbenchMaintenance() async {
    for id in Array(workbenchMaintenanceAdmissions.keys) {
      await finishWorkbenchMaintenance(operationID: id)
    }
  }
}
