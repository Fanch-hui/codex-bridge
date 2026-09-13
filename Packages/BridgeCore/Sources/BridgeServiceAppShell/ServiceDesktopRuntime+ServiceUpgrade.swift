import Foundation

extension BridgeServiceAppModel {
  func scheduleServiceUpgradeIfNeeded() {
    guard registration.supportsAutomaticRecovery, !didAttemptServiceUpgrade,
      !stopped, connectionState == .connected, !agentProviders.isEmpty,
      agentProviders.allSatisfy({ $0.discoveryState == nil }) || directConfiguration == nil,
      let status = serviceStatus?.status,
      !["active", "pending"].contains(status.executionState),
      status.pendingApprovalCount == 0, !tasks.contains(where: \.isActive)
    else { return }
    didAttemptServiceUpgrade = true
    Task { [weak self] in
      await self?.upgradeService()
    }
  }

  private func upgradeService() async {
    guard !stopped else { return }
    do {
      guard try await registration.recoverUnavailableService(), !stopped else { return }
      await connect(includeCatalog: true, recoverRegistration: false)
    } catch {
      errorMessage = Self.message(error)
    }
  }
}
