#if os(Windows)
  import BridgeDesktopUI
  import BridgeServiceAppCore
  import Foundation

  extension CodexBridgeWindowsApplication {
    static var appUpdater: AppUpdateController?
    static var appUpdateState: BridgeDesktopAppUpdateState?
    static var appUpdateRevision: UInt64 = 0

    static func makeAppUpdater(model: WindowsWorkbenchModel) -> AppUpdateController {
      let installer = WindowsAppUpdateInstaller()
      let updater = AppUpdateController(
        currentVersion: WindowsAppUpdateInstaller.currentVersion,
        platform: "windows",
        architecture: WindowsAppUpdateInstaller.architecture,
        kind: installer.installationKind.rawValue,
        preparePackage: { package, release in
          try await installer.preparePackage(package, release: release)
        },
        acquireInstallation: { [weak model] in
          guard let model else { throw CancellationError() }
          return try await model.client.prepareAppUpdate()
        },
        installPackage: { [weak model] in
          model?.stopSchedulingForApplicationExit()
          try await installer.installPackage()
        },
        cancelInstallation: { [weak model] in
          installer.cancelPackage()
          try? await model?.client.cancelAppUpdate()
          model?.resumeAfterAppUpdateCancellation()
        }
      )
      updater.onChange = { status in
        appUpdateState = BridgeDesktopAppUpdateState(status: status)
        appUpdateRevision &+= 1
      }
      appUpdateState = BridgeDesktopAppUpdateState(status: updater.state)
      return updater
    }

    static func startAppUpdateCheck(model: WindowsWorkbenchModel) {
      let updater = makeAppUpdater(model: model)
      appUpdater = updater
      if let message = WindowsAppUpdateInstaller.consumeFailureReceipt() {
        model.feedback.postAlert(message, title: "上次更新未完成")
      }
      updater.start()
    }
  }
#endif
