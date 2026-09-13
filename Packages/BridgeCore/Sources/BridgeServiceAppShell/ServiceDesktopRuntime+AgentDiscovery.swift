import Foundation

extension BridgeServiceAppModel {
  func scheduleAgentDiscoveryUpgradeIfNeeded() {
    guard registration.supportsAutomaticRecovery, !didAttemptAgentDiscoveryUpgrade,
      !stopped, connectionState == .connected, !agentProviders.isEmpty,
      agentProviders.allSatisfy({ $0.discoveryState == nil }),
      let status = serviceStatus?.status,
      !["active", "pending"].contains(status.executionState),
      status.pendingApprovalCount == 0, !tasks.contains(where: \.isActive)
    else { return }
    didAttemptAgentDiscoveryUpgrade = true
    Task { [weak self] in
      await self?.upgradeAgentDiscoveryService()
    }
  }

  private func upgradeAgentDiscoveryService() async {
    guard !stopped else { return }
    do {
      guard try await registration.recoverUnavailableService(), !stopped else { return }
      await connect(includeCatalog: true, recoverRegistration: false)
    } catch {
      errorMessage = Self.message(error)
    }
  }
}
