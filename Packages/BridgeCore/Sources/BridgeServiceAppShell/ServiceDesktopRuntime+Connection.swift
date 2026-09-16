import BridgeIPC
import BridgeServiceAppCore
import Foundation

extension BridgeServiceAppModel {
  func connect(
    includeCatalog: Bool,
    forceCatalogRefresh: Bool = false,
    recoverRegistration: Bool = true
  ) async {
    pollingTask?.cancel()
    pollingTask = nil
    await closeClient()
    registrationStatus = registration.status
    guard registrationStatus == .enabled else {
      connectionState =
        registrationStatus == .requiresApproval
        ? .requiresApproval
        : .unavailable
      return
    }

    connectionState = .connecting
    var lastError: (any Error)?
    let attempts =
      recoverRegistration ? min(maximumConnectionAttempts, 3) : maximumConnectionAttempts
    for attempt in 0..<attempts {
      guard !stopped, registration.status == .enabled else { return }
      let candidate = clientFactory()
      do {
        let status = try await candidate.status()
        serviceStatus = status
        applyWorkbenchPermissionMode(status.workbenchPermissionMode)
        client = candidate
        connectionState = .connected
        registrationStatus = .enabled
        lastRefreshAt = Date()
        errorMessage = nil
        await refreshCollections(
          client: candidate,
          includeCatalog: includeCatalog,
          includeProjectResources: true,
          forceCatalogRefresh: forceCatalogRefresh
        )
        startPolling()
        return
      } catch {
        lastError = error
        await candidate.close()
        guard attempt + 1 < attempts else { break }
        do {
          try await Task.sleep(for: connectionRetryDelay)
        } catch {
          return
        }
      }
    }

    if recoverRegistration, !stopped {
      do {
        if try await registration.recoverUnavailableService() {
          await connect(
            includeCatalog: includeCatalog,
            forceCatalogRefresh: forceCatalogRefresh,
            recoverRegistration: false
          )
          return
        }
      } catch {
        lastError = error
      }
    }
    registrationStatus = registration.status
    connectionState =
      registrationStatus == .requiresApproval
      ? .requiresApproval
      : .unavailable
    if let lastError {
      errorMessage = Self.message(lastError)
    }
    startPolling()
  }

}
