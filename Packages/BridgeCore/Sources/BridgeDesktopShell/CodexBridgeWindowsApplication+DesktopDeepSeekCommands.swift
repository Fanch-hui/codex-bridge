#if os(Windows) || os(Linux)
  import BridgeDesktopUI

  extension CodexBridgeDesktopApplication {
    static func runDesktopDeepSeekCommand(
      _ envelope: BridgeDesktopCommandEnvelope,
      model: WindowsWorkbenchModel, management: WindowsManagementModel,
      auxiliary: WindowsAuxiliaryRuntime
    ) -> Bool {
      switch envelope.command {
      case .manageDeepSeekHarnessDesktop:
        Task { @MainActor in
          await management.manageDeepSeekDesktop(envelope.payload)
          await auxiliary.agentDefaults.refresh()
        }
      case .openDeepSeekHarnessSession:
        Task { @MainActor in
          let task = envelope.payload.taskID.flatMap { id in model.tasks.first { $0.taskID == id } }
          await management.openDeepSeekDesktopSession(envelope.payload, task: task)
        }
      default: return false
      }
      return true
    }
  }
#endif
