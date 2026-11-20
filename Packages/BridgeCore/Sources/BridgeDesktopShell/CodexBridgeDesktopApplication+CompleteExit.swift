#if os(Windows) || os(Linux)
  import BridgeServiceAppCore
  import Foundation
  #if os(Windows)
    import WinSDK
  #else
    import BridgeIPC
  #endif

  extension CodexBridgeDesktopApplication {
    static func beginCompleteExit(model: WindowsWorkbenchModel) {
      guard !completeExitInProgress else { return }
      completeExitInProgress = true
      model.feedback.postToast("正在等待后台请求完成后退出。", title: "正在退出", tone: .running)
      #if os(Windows)
        WindowsUIThread.shared.enqueue {
          WindowsMainWindowChrome.restore(WindowsMainWindow.currentWindow())
        }
      #else
        LinuxDesktopHost.show()
      #endif
      Task {
        defer { completeExitInProgress = false }
        do {
          if !completeExitServicePrepared {
            try await CompleteServiceExit.prepare(using: model.client)
            completeExitServicePrepared = true
          }
          model.stopSchedulingForApplicationExit()
          #if os(Windows)
            let stopped = await Task.detached { WindowsServiceLauncher.shutdownServiceAndWait() }
              .value
            guard stopped else {
              throw CompleteServiceExitError.failed("后台服务尚未确认退出，请稍后重试。")
            }
            completedServiceExit = true
            WindowsUIThread.shared.enqueue {
              guard let window = WindowsMainWindow.currentWindow() else { return }
              WindowsMainWindowLifecycle.requestExit(window)
            }
          #else
            try await LinuxServiceControl.shutdownAndWait()
            completedServiceExit = true
            LinuxDesktopHost.stop()
          #endif
        } catch {
          model.feedback.postAlert(BridgeServiceErrorMessage.message(error), title: "无法彻底退出")
          #if os(Windows)
            WindowsUIThread.shared.enqueue {
              WindowsMainWindowChrome.restore(WindowsMainWindow.currentWindow())
            }
          #else
            LinuxDesktopHost.show()
          #endif
        }
      }
    }
  }
#endif
