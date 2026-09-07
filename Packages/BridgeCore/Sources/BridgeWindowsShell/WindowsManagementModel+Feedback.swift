#if os(Windows)
  extension WindowsManagementModel {
    func reportProjectSuccess(_ message: String, projectID: String? = nil) {
      if projectID == nil || selectedProjectID == projectID { setProjectStatus(message) }
      feedback.postToast(message)
    }

    func reportProjectFailure(_ message: String, projectID: String? = nil) {
      if projectID == nil || selectedProjectID == projectID { setProjectStatus(message) }
      feedback.postAlert(message, title: "项目操作失败")
    }

    func reportAgentSuccess(_ message: String, installationID: String? = nil) {
      if installationID == nil || selectedInstallationID == installationID {
        setAgentStatus(message)
      }
      feedback.postToast(message)
    }

    func reportAgentFailure(_ message: String, installationID: String? = nil) {
      if installationID == nil || selectedInstallationID == installationID {
        setAgentStatus(message)
      }
      feedback.postAlert(message, title: "Agent 操作失败")
    }
  }
#endif
