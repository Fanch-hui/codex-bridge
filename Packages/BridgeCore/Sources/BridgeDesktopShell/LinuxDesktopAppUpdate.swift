#if os(Linux)
  import BridgeDesktopUI
  import BridgeIPC
  import BridgeServiceAppCore
  import Foundation

  extension CodexBridgeDesktopApplication {
    static var appUpdater: LinuxDesktopAppUpdate?
    static var appUpdateState: BridgeDesktopAppUpdateState?
    static var appUpdateRevision: UInt64 = 0

    static func startAppUpdateCheck(model: WindowsWorkbenchModel) {
      let updater = LinuxDesktopAppUpdate(feedback: model.feedback)
      appUpdater = updater
      updater.check(automatically: true)
    }
  }

  @MainActor
  final class LinuxDesktopAppUpdate {
    private let feedback: WindowsDesktopFeedbackStore
    private let client = AppUpdateClient()
    private var state = AppUpdateStatus(currentVersion: LinuxDesktopAppUpdate.currentVersion)
    private var release: AppUpdateRelease?
    private var operation: Task<Void, Never>?

    init(feedback: WindowsDesktopFeedbackStore) {
      self.feedback = feedback
      publish()
    }

    private static var currentVersion: String {
      guard let directory = LinuxServiceEndpoint.executableURL()?.deletingLastPathComponent(),
        let data = try? Data(contentsOf: directory.appendingPathComponent("BUILD-INFO.json")),
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let version = object["appVersion"] as? String
      else { return "0.0.0" }
      return version
    }

    func check(automatically: Bool = false) {
      guard operation == nil else { return }
      state.phase = "checking"
      state.message = nil
      state.isDeferred = false
      publish()
      operation = Task { [weak self] in
        guard let self else { return }
        defer { operation = nil }
        do {
          #if arch(arm64)
            let architecture = "arm64"
          #else
            let architecture = "x64"
          #endif
          release = try await client.check(
            currentVersion: state.currentVersion,
            platform: "linux", architecture: architecture, kind: "installer")
          try Task.checkCancellation()
          state.availableVersion = release?.manifest.version
          state.notes = release?.manifest.notes
          state.phase = release == nil ? "upToDate" : "available"
        } catch {
          guard !Task.isCancelled else { return }
          state.phase = automatically ? "idle" : "failed"
          state.message = automatically ? nil : error.localizedDescription
        }
        publish()
      }
    }

    func install() {
      guard let release else { return }
      LinuxDesktopHost.openExternalURL(release.asset.url.absoluteString)
      feedback.postAlert(
        "已打开 Ubuntu 安装包下载地址。下载后使用系统软件安装器安装，并重新启动 Codex Bridge。",
        title: "安装 Codex Bridge 更新")
      state.isDeferred = true
      publish()
    }

    func deferUpdate() {
      state.isDeferred = true
      publish()
    }

    func cancel() { operation?.cancel() }

    private func publish() {
      CodexBridgeDesktopApplication.appUpdateState = BridgeDesktopAppUpdateState(status: state)
      CodexBridgeDesktopApplication.appUpdateRevision &+= 1
    }
  }
#endif
