#if os(Windows) || os(Linux)
  import BridgeIPC
  import BridgeServiceAppCore

  extension WindowsManagementModel {
    func cancelDeepSeekDesktopPairing() {
      deepSeekDesktopPairingGeneration &+= 1
      deepSeekDesktopPairingTask?.cancel()
      deepSeekDesktopPairingTask = nil
    }

    func observeDeepSeekDesktopPairing(
      _ state: DeepSeekHarnessDesktopState, installationID: String
    ) {
      guard !state.desktop.paired, state.desktop.pairingCode != nil else { return }
      cancelDeepSeekDesktopPairing()
      let generation = deepSeekDesktopPairingGeneration
      let client = client
      deepSeekDesktopPairingTask = Task { [weak self] in
        do {
          let latest = try await DeepSeekDesktopConnection.waitForPairing(
            installationID: installationID, client: client, initialState: state
          ) { [weak self] value in
            guard let self, connectionState == .connected,
              deepSeekDesktopPairingGeneration == generation
            else { return false }
            applyDeepSeekDesktop(value, installationID: installationID)
            publishDisplay()
            return true
          }
          guard let self, deepSeekDesktopPairingGeneration == generation else { return }
          deepSeekDesktopPairingTask = nil
          if latest?.desktop.connected == true, latest?.desktop.paired == true {
            agentOperationRevision &+= 1
            await refreshAgents()
          }
        } catch is CancellationError {
        } catch {
          guard let self, deepSeekDesktopPairingGeneration == generation else { return }
          deepSeekDesktopPairingTask = nil
          reportAgentFailure(BridgeServiceErrorMessage.message(error))
          publishDisplay()
        }
      }
    }
  }
#endif
