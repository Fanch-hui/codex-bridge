#if os(Windows)
  extension WindowsManagementModel {
    func reportProjectSuccess(_ message: String) {
      setProjectStatus(message)
      feedback.postToast(message)
    }

    func reportProjectFailure(_ message: String) {
      setProjectStatus(message)
      feedback.postAlert(message, title: "项目操作失败")
    }

    func reportAgentSuccess(_ message: String) {
      setAgentStatus(message)
      feedback.postToast(message)
    }

    func reportAgentFailure(_ message: String) {
      setAgentStatus(message)
      feedback.postAlert(message, title: "Agent 操作失败")
    }
  }
#endif
