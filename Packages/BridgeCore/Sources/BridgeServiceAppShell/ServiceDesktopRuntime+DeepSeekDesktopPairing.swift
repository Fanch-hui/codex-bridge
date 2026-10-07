import BridgeIPC
import BridgeServiceAppCore

extension BridgeServiceAppModel {
  func cancelDeepSeekDesktopPairing() {
    deepSeekDesktopPairingGeneration &+= 1
    deepSeekDesktopPairingTask?.cancel()
    deepSeekDesktopPairingTask = nil
  }

  func observeDeepSeekDesktopPairing(
    _ state: DeepSeekHarnessDesktopState, installationID: String
  ) {
    guard !state.desktop.paired, state.desktop.pairingCode != nil,
      let client = try? currentClient()
    else { return }
    cancelDeepSeekDesktopPairing()
    let generation = deepSeekDesktopPairingGeneration
    deepSeekDesktopPairingTask = Task { [weak self] in
      do {
        let latest = try await DeepSeekDesktopConnection.waitForPairing(
          installationID: installationID, client: client, initialState: state
        ) { [weak self] value in
          guard let self, connectionState == .connected,
            deepSeekDesktopPairingGeneration == generation
          else { return false }
          applyDeepSeekDesktop(value, installationID: installationID)
          return true
        }
        guard let self, deepSeekDesktopPairingGeneration == generation else { return }
        deepSeekDesktopPairingTask = nil
        if latest?.desktop.connected == true, latest?.desktop.paired == true {
          applyAgentCatalogSnapshot(try await client.agentCatalog())
          refreshAgentModelCatalog(
            installationID: installationID, providerID: "deepseek-harness-desktop")
          await refresh(silent: true, includeCatalog: true)
        }
      } catch is CancellationError {
      } catch {
        guard let self, deepSeekDesktopPairingGeneration == generation else { return }
        deepSeekDesktopPairingTask = nil
        errorMessage = Self.message(error)
      }
    }
  }
}
