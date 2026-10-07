import AppKit
import BridgeAgentCore
import BridgeDesktopUI
import BridgeIPC
import BridgeServiceAppCore
import Foundation

extension BridgeServiceAppModel {
  func refreshDeepSeekDesktopStates() {
    guard !deepSeekDesktopRefreshInFlight, connectionState == .connected else { return }
    let installations = agentInstallations.filter { $0.providerID == "deepseek-harness-desktop" }
    guard !installations.isEmpty else {
      deepSeekDesktopStates = [:]
      return
    }
    deepSeekDesktopRefreshInFlight = true
    Task { [weak self] in
      guard let self else { return }
      defer { deepSeekDesktopRefreshInFlight = false }
      for installation in installations {
        if let value = try? await currentClient().manageDeepSeekHarnessDesktop(
          .init(installationID: installation.installationID))
        {
          applyDeepSeekDesktop(value, installationID: installation.installationID)
          if deepSeekDesktopPairingTask == nil {
            observeDeepSeekDesktopPairing(value, installationID: installation.installationID)
          }
        }
      }
    }
  }

  func manageDeepSeekDesktop(_ payload: BridgeDesktopCommandPayload) {
    if payload.action == "discover"
      || (payload.action == "installConnector"
        && BridgeDesktopCommandValue.nonEmpty(payload.installationID) == nil)
    {
      discoverDeepSeekDesktop(installConnector: payload.action == "installConnector")
      return
    }
    guard !deepSeekDesktopBusy,
      let installationID = BridgeDesktopCommandValue.nonEmpty(payload.installationID),
      agentInstallations.contains(where: {
        $0.installationID == installationID && $0.providerID == "deepseek-harness-desktop"
      }), let action = DeepSeekHarnessDesktopAction(rawValue: payload.action ?? "status"),
      action != .openSession
    else { return }
    let mode = payload.mode.flatMap(DeepSeekHarnessConnectionMode.init(rawValue:))
    guard action != .setMode || mode != nil else { return }
    if action != .status { cancelDeepSeekDesktopPairing() }
    deepSeekDesktopBusy = true
    Task { [weak self] in
      guard let self else { return }
      defer { deepSeekDesktopBusy = false }
      do {
        let client = try currentClient()
        let value = try await DeepSeekDesktopConnection.perform(
          .init(installationID: installationID, action: action, mode: mode), client: client,
          launchApplication: { try await DeepSeekDesktopApplicationHost.open(executablePath: $0) })
        applyDeepSeekDesktop(value, installationID: installationID)
        if action == .connect || action == .pair {
          observeDeepSeekDesktopPairing(value, installationID: installationID)
        }
        applyAgentCatalogSnapshot(try await client.agentCatalog())
        if action == .setMode || value.desktop.paired {
          refreshAgentModelCatalog(
            installationID: installationID, providerID: "deepseek-harness-desktop")
          await refresh(silent: true, includeCatalog: true)
        }
      } catch {
        errorMessage = Self.message(error)
        if let current = try? await currentClient().manageDeepSeekHarnessDesktop(
          .init(installationID: installationID))
        {
          applyDeepSeekDesktop(current, installationID: installationID)
        }
      }
    }
  }

  private func discoverDeepSeekDesktop(installConnector: Bool = false) {
    guard !deepSeekDesktopBusy else { return }
    deepSeekDesktopBusy = true
    cancelDeepSeekDesktopPairing()
    Task { [weak self] in
      guard let self else { return }
      defer { deepSeekDesktopBusy = false }
      do {
        let client = try currentClient()
        let installation = try await client.connectAgentInstallation(
          .init(
            providerID: "deepseek-harness-desktop", connectionMode: "native-desktop"))
        let value = try await client.manageDeepSeekHarnessDesktop(
          .init(
            installationID: installation.installationID,
            action: installConnector ? .installConnector : .status))
        applyDeepSeekDesktop(value, installationID: installation.installationID)
        applyAgentCatalogSnapshot(try await client.agentCatalog())
      } catch { errorMessage = Self.message(error) }
    }
  }

  func openDeepSeekDesktopSession(_ payload: BridgeDesktopCommandPayload) {
    let task = payload.taskID.flatMap { id in tasks.first { $0.taskID == id } }
    let installationID = task?.installationID ?? payload.installationID
    let projectID = task?.projectID ?? payload.projectID
    let sessionID = task?.threadID ?? payload.sessionID
    guard let installationID, let projectID, task != nil || sessionID != nil,
      agentInstallations.contains(where: {
        $0.installationID == installationID
          && ($0.providerID == "deepseek-harness-desktop"
            || (task != nil && $0.providerID == "deepseek-harness"))
      })
    else { return }
    Task { [weak self] in
      guard let self else { return }
      do {
        let client = try currentClient()
        var value = try await client.manageDeepSeekHarnessDesktop(
          .init(installationID: installationID))
        guard value.canOpenSession else { throw BridgeServiceClientError.unavailable }
        try await DeepSeekDesktopApplicationHost.open(
          executablePath: value.executablePath, activates: false)
        if !value.desktop.connected {
          for _ in 0..<20 {
            try await Task.sleep(for: .milliseconds(500))
            value = try await client.manageDeepSeekHarnessDesktop(
              .init(installationID: installationID))
            if value.desktop.connected { break }
          }
        }
        try await navigateDeepSeekDesktop(
          .init(
            installationID: installationID,
            action: .openSession, projectID: projectID, sessionID: sessionID, taskID: task?.taskID),
          client: client, executablePath: value.executablePath)
        try await DeepSeekDesktopApplicationHost.open(executablePath: value.executablePath)
      } catch { errorMessage = Self.message(error) }
    }
  }

  private func navigateDeepSeekDesktop(
    _ request: DeepSeekHarnessDesktopRequest, client: any BridgeServiceClientProtocol,
    executablePath: String
  ) async throws {
    for attempt in 0..<20 {
      do {
        _ = try await client.manageDeepSeekHarnessDesktop(request)
        return
      } catch BridgeServiceIPCCodecError.remoteError(let error)
        where error.code == "desktop_ui_unavailable" && attempt < 19
      {
        if attempt == 0 {
          try await DeepSeekDesktopApplicationHost.open(executablePath: executablePath)
        }
        try await Task.sleep(for: .milliseconds(500))
      }
    }
  }

  func applyDeepSeekDesktop(_ value: DeepSeekHarnessDesktopState, installationID: String) {
    deepSeekDesktopStates[installationID] = .init(
      installationID: installationID,
      mode: value.mode.rawValue, connected: value.desktop.connected, paired: value.desktop.paired,
      pairingCode: value.desktop.pairingCode, profileID: value.desktop.profileID,
      message: value.desktop.unavailableReason,
      errorCode: value.desktop.errorCode,
      executablePath: value.executablePath, connectorInstalled: value.connectorInstalled,
      canInstallConnector: value.canInstallConnector)
    synchronizeAgentModelScopes()
  }
}

@MainActor
private enum DeepSeekDesktopApplicationHost {
  static func open(executablePath: String, activates: Bool = true) async throws {
    let executable = URL(fileURLWithPath: executablePath).standardizedFileURL
    var application = executable
    while application.path != "/", application.pathExtension != "app" {
      application.deleteLastPathComponent()
    }
    guard application.pathExtension == "app",
      FileManager.default.fileExists(atPath: executable.path)
    else { throw BridgeServiceClientError.unavailable }
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = activates
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      NSWorkspace.shared.openApplication(at: application, configuration: configuration) {
        _, error in
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
      }
    }
  }
}
