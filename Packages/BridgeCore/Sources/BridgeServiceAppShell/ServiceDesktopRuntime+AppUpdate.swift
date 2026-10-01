import AppKit
import BridgeDesktopUI
import BridgeServiceAppCore
import Foundation

extension BridgeServiceAppModel {
  public var isPreparedForUpdateTermination: Bool {
    stopped && appUpdateState?.phase == "installing"
  }

  func makeAppUpdater() -> AppUpdateController {
    let installer = MacAppUpdateInstaller()
    #if arch(arm64)
      let architecture = "arm64"
    #else
      let architecture = "x64"
    #endif
    let updater = AppUpdateController(
      currentVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
        as? String ?? "1.3.3",
      platform: "macos", architecture: architecture, kind: "app",
      preparePackage: { archive, release in try await installer.prepare(archive, release: release)
      },
      acquireInstallation: { [weak self] in
        guard let self else { throw CancellationError() }
        return try await self.currentClient().prepareAppUpdate()
      },
      installPackage: { [weak self] in
        guard let self else { throw CancellationError() }
        self.userDefaults.set(true, forKey: "CodexBridgeJustUpdated")
        let servicePIDs = try await MacAppUpdateServiceExit.processIDs()
        try await installer.launch()
        self.pollingTask?.cancel()
        self.pollingTask = nil
        try await self.registration.unregister()
        try await MacAppUpdateServiceExit.wait(for: servicePIDs)
        await self.shutdownUI()
        NSApp.terminate(nil)
      },
      cancelInstallation: { [weak self] in
        installer.cancel()
        guard let self else { return }
        self.userDefaults.removeObject(forKey: "CodexBridgeJustUpdated")
        try? await self.client?.cancelAppUpdate()
        if self.registration.status == .notRegistered {
          await self.enableBackgroundService()
        }
        self.startPolling()
      }
    )
    updater.onChange = { [weak self] status in
      self?.appUpdateState = BridgeDesktopAppUpdateState(status: status)
    }
    appUpdateState = BridgeDesktopAppUpdateState(status: updater.state)
    return updater
  }

  func startAppUpdateCheck() {
    guard registration.supportsAutomaticRecovery else { return }
    if let message = try? String(contentsOf: MacAppUpdateHelper.failureURL, encoding: .utf8) {
      postToast(message, symbol: "exclamationmark.triangle", tone: .warning)
      try? FileManager.default.removeItem(at: MacAppUpdateHelper.failureURL)
    }
    let currentVersion =
      Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.3.3"
    let lastSeenVersionKey = "CodexBridgeLastSeenVersion"
    let justUpdatedKey = "CodexBridgeJustUpdated"
    let previousVersion = userDefaults.string(forKey: lastSeenVersionKey)
    let justUpdated = userDefaults.bool(forKey: justUpdatedKey)
    if justUpdated || (previousVersion != nil && previousVersion != currentVersion) {
      postToast(
        "在 ChatGPT 的插件设置中找到 Codex Bridge，点击刷新，让新工具和模型列表生效。",
        symbol: "arrow.clockwise.circle.fill",
        tone: .warning,
        title: "应用已更新，请刷新 ChatGPT 插件",
        duration: .seconds(10)
      )
      userDefaults.removeObject(forKey: justUpdatedKey)
    }
    userDefaults.set(currentVersion, forKey: lastSeenVersionKey)
    appUpdater.start()
  }
}
