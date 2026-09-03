#if os(Windows)
  import BridgeDesktopUI
  import BridgeIPC
  import Foundation

  extension WindowsSettingsModel {
    func registerService() async {
      do {
        try WindowsServiceRegistration.register()
        serviceRegistered = true
        statusText = "已注册开机自启动后台服务。"
        feedback.postToast("已注册开机自启动后台服务")
      } catch {
        statusText = "注册后台服务失败：\(BridgeServiceErrorMessage.message(error))"
        feedback.postAlert(statusText)
      }
      publishDisplay()
    }

    func unregisterService() async {
      do {
        try WindowsServiceRegistration.unregister()
        serviceRegistered = false
        statusText = "已注销开机自启动后台服务。"
        feedback.postToast("已注销开机自启动后台服务")
      } catch {
        statusText = "注销后台服务失败：\(BridgeServiceErrorMessage.message(error))"
        feedback.postAlert(statusText)
      }
      publishDisplay()
    }

    func setKeepServiceRunningAfterExit(_ value: Bool) {
      keepServiceRunningAfterExit = value
      UserDefaults.standard.set(value, forKey: "keepServiceRunningAfterAppExit")
      publishDisplay()
    }
  }
#endif
