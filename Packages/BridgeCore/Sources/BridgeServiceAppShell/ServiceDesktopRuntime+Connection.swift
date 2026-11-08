import BridgeIPC
import BridgeServiceAppCore
import Foundation

extension BridgeServiceAppModel {
  /// Probing spawns `launchctl`, so a healthy connection is trusted instead of re-probed on every
  /// refresh. A lost service fails the next request, which drops the client and sends the
  /// following refresh through a real probe. Service switches pass `reprobe` to always ask.
  @discardableResult
  func resolveRegistrationStatus(reprobe: Bool = false) async -> BridgeServiceRegistrationStatus {
    if !reprobe, client != nil, connectionState == .connected, registrationStatus == .enabled {
      return registrationStatus
    }
    let status = await registration.probeStatus()
    if registrationStatus != status { registrationStatus = status }
    return status
  }

  func connect(
    includeCatalog: Bool,
    forceCatalogRefresh: Bool = false,
    recoverRegistration: Bool = true,
    includeCollections: Bool = true
  ) async {
    pollingTask?.cancel()
    pollingTask = nil
    await closeClient()
    await resolveRegistrationStatus()
    guard registrationStatus == .enabled else {
      connectionState =
        registrationStatus == .requiresApproval
        ? .requiresApproval
        : .unavailable
      startPolling()
      return
    }

    connectionState = .connecting
    var lastError: (any Error)?
    let attempts =
      recoverRegistration ? min(maximumConnectionAttempts, 3) : maximumConnectionAttempts
    for attempt in 0..<attempts {
      guard !stopped else { return }
      // Attempt 0 follows the probe above with no suspension in between.
      if attempt > 0, await registration.probeStatus() != .enabled { break }
      let candidate = clientFactory()
      do {
        let status = try await candidate.status()
        serviceStatus = status
        applyWorkbenchPermissionMode(status.workbenchPermissionMode)
        client = candidate
        await observeServiceChanges(candidate)
        connectionState = .connected
        registrationStatus = .enabled
        lastRefreshAt = Date()
        errorMessage = nil
        await workbenchSettingsController.refresh()
        if includeCollections {
          await refreshCollections(
            client: candidate,
            includeCatalog: includeCatalog,
            includeProjectResources: true,
            forceCatalogRefresh: forceCatalogRefresh
          )
        }
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
            recoverRegistration: false,
            includeCollections: includeCollections
          )
          return
        }
      } catch {
        lastError = error
      }
    }
    await resolveRegistrationStatus()
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
