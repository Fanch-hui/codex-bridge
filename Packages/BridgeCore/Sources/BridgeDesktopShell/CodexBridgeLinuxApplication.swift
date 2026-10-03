#if os(Linux)
  import BridgeDesktopUI
  import BridgeIPC
  import Foundation

  extension CodexBridgeDesktopApplication {
    public static func main() async {
      let feedback = WindowsDesktopFeedbackStore()
      let model = WindowsWorkbenchModel(feedback: feedback)
      let management = WindowsManagementModel(client: model.client, feedback: feedback)
      let auxiliary = WindowsAuxiliaryRuntime(client: model.client, feedback: feedback)
      guard LinuxDesktopHost.start() else {
        FileHandle.standardError.write(Data("无法初始化 GTK / WebKitGTK 桌面环境。\n".utf8))
        return
      }
      model.onConnected = { [weak model, weak management, weak auxiliary] in
        guard let model, !model.isShuttingDown, let management, let auxiliary else { return }
        await management.refreshProjects()
        guard !model.isShuttingDown else { return }
        Task(priority: .utility) {
          await management.refreshAgents()
          guard !model.isShuttingDown else { return }
          await auxiliary.agentDefaults.refresh()
        }
        if selectedPage != .overview {
          refresh(page: selectedPage, model: model, management: management, auxiliary: auxiliary)
        }
      }
      startAppUpdateCheck(model: model)
      Task { await model.startServiceAndConnect() }
      var rendering = LinuxDesktopRendering()
      while LinuxDesktopHost.isRunning {
        let resync = LinuxDesktopHost.receiveEvents()
        let commands = LinuxDesktopHost.takeCommands()
        for command in commands {
          run(command, model: model, management: management, auxiliary: auxiliary)
        }
        if !commands.isEmpty { model.userDidInteract() }
        rendering.apply(
          model: model, management: management, auxiliary: auxiliary, fullState: resync)
        try? await Task.sleep(for: .milliseconds(30))
      }
      appUpdater?.cancel()
      if !auxiliary.settings.keepServiceRunningAfterExit,
        let client = model.client as? BridgeServiceClient
      {
        _ = try? await client.shutdownService()
      }
      await model.shutdown()
    }

    static func updateWindowVisibility(_ visible: Bool, model: WindowsWorkbenchModel) {
      model.setWindowVisible(visible)
    }

    static func updateBrowserMemoryPolicy(model: WindowsWorkbenchModel) {
      LinuxDesktopHost.setBrowserEnabled(model.isChatBrowserEnabled)
    }

    nonisolated static func openChatExternally() {
      LinuxDesktopHost.openExternalURL("https://chatgpt.com/")
    }
  }

  @MainActor
  private struct LinuxDesktopRendering {
    private var revisions: [UInt64] = []
    private var page: WindowsMainPage?
    private var feedback: BridgeDesktopFeedback?
    private var browser = LinuxDesktopHost.BrowserSnapshot()
    private var patchBuilder = BridgeDesktopUIStatePatchBuilder()
    private var state: BridgeDesktopUIState?
    private var revision: UInt64 = 0

    mutating func apply(
      model: WindowsWorkbenchModel,
      management: WindowsManagementModel,
      auxiliary: WindowsAuxiliaryRuntime,
      fullState: Bool
    ) {
      auxiliary.connections.applyServiceStatus(
        model.serviceStatus, connectionState: model.connectionState)
      let nextRevisions = [
        model.displayBox.revision, management.displayBox.revision,
        auxiliary.workspace.displayBox.revision, auxiliary.logs.displayBox.revision,
        auxiliary.connections.displayBox.revision, auxiliary.settings.displayBox.revision,
        auxiliary.agentDefaults.displayBox.revision,
        CodexBridgeDesktopApplication.appUpdateRevision,
      ]
      let nextPage = CodexBridgeDesktopApplication.selectedPage
      let nextFeedback = model.feedback.current
      let nextBrowser = LinuxDesktopHost.browser
      if revisions != nextRevisions || page != nextPage || feedback != nextFeedback
        || browser != nextBrowser || state == nil
      {
        revisions = nextRevisions
        page = nextPage
        feedback = nextFeedback
        browser = nextBrowser
        revision &+= 1
        let display = model.displayBox.current()
        let snapshot = auxiliary.desktopDisplaySnapshot()
        let nextState = WindowsDesktopUIStateBuilder.build(
          workbench: display,
          management: management.displayBox.current(),
          workspace: snapshot.workspace, logs: snapshot.logs,
          connections: snapshot.connections, settings: snapshot.settings,
          agentDefaults: snapshot.agentDefaults,
          selectedNavigation: nextPage.desktopNavigation,
          browserAvailable: browser.state != "failed",
          browserURL: browser.url,
          browserStatus: browser.error ?? (browser.state == "loading" ? "正在加载聊天页…" : browser.url),
          browserCanGoBack: browser.canGoBack, browserCanGoForward: browser.canGoForward,
          feedback: feedback, appUpdate: CodexBridgeDesktopApplication.appUpdateState)
        state = nextState
        LinuxDesktopHost.setBrowserEnabled(
          display.browserEnabled && nextPage == .workbench && feedback?.kind != .alert)
        let patch = patchBuilder.makePatch(state: nextState, nextRevision: revision)
        if !fullState { LinuxDesktopHost.send(patch) }
      }
      if fullState, let state {
        LinuxDesktopHost.send(patchBuilder.fullSnapshot(state: state, revision: revision))
      }
    }
  }
#endif
