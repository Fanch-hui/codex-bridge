#if os(Windows)
  extension WindowsWorkspaceModel {
    func refreshSelected() async {
      guard connectionState == .connected else {
        reportFailure("后台 Service 未连接。")
        return
      }
      guard !busy else { return }
      await loadSelectedWorkspace()
    }

    func refreshDisplaySnapshot() {
      publishDisplay()
    }

    func reportSuccess(_ message: String) {
      statusText = message
      feedback.postToast(message)
      publishDisplay()
    }

    func reportFailure(_ message: String) {
      statusText = message
      feedback.postAlert(message, title: "项目配置失败")
      publishDisplay()
    }
  }
#endif
