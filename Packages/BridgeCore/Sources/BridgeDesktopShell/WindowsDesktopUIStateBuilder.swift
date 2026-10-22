#if os(Windows) || os(Linux)
  import BridgeDesktopUI
  import BridgeServiceAppCore
  import Foundation

  /// Projects model snapshots into the shared desktop UI contract.
  enum WindowsDesktopUIStateBuilder {
    private static let pageCache = WindowsDesktopUIStatePageCache()

    static func build(
      workbench: WindowsWorkbenchDisplay,
      management: WindowsManagementDisplay,
      workspace: WindowsWorkspaceDisplay? = nil,
      logs: WindowsLogDisplay? = nil,
      connections: WindowsConnectionDisplay? = nil,
      settings: WindowsSettingsDisplay? = nil,
      agentDefaults: WindowsAgentDefaultsDisplay? = nil,
      selectedNavigation: BridgeDesktopNavigation = .overview,
      isRefreshing: Bool = false,
      browserAvailable: Bool = true,
      browserSite: ChatBrowserSite = .chatGPT,
      browserURL: String? = nil,
      browserStatus: String? = nil,
      browserCanGoBack: Bool = false,
      browserCanGoForward: Bool = false,
      feedback: BridgeDesktopFeedback? = nil,
      appUpdate: BridgeDesktopAppUpdateState? = nil
    ) -> BridgeDesktopUIState {
      let startedAt = ContinuousClock.now
      let modelRefreshInProgress = settings?.isRefreshingModels == true
      let canRefreshModels = settings?.busy != true
      let agentReconnectSummary = agentReconnectSummary(from: management)
      let state = BridgeDesktopUIState(
        hostContext: BridgeDesktopHostContext(platform: DesktopPlatformHost.platform),
        navigation: pageCache.navigation(
          key: WindowsDesktopNavigationCacheKey(
            runningTaskCount: workbench.runningTaskCount,
            pendingApprovalCount: workbench.pendingApprovalCount,
            projectCount: management.project.rows.count
          )
        ) {
          navigation(workbench: workbench, management: management)
        },
        selectedNavigation: selectedNavigation,
        connectionLabel: connectionLabel(for: workbench.connectionState),
        connectionTone: connectionTone(for: workbench.connectionState),
        isRefreshing: isRefreshing,
        feedback: feedback,
        overview: pageCache.overview(
          key: WindowsDesktopOverviewCacheKey(
            connectionState: workbench.connectionState,
            mcpState: workbench.mcpState,
            detailText: workbench.detailText,
            runningTaskCount: workbench.runningTaskCount,
            pendingApprovalCount: workbench.pendingApprovalCount,
            taskCount: workbench.taskCount,
            projectCount: management.project.rows.count,
            installationCount: management.agent.installationRows.count,
            availableAgentCount: management.availableAgentCount,
            agentReconnectSummary: agentReconnectSummary,
            recentTasks: workbench.recentTasks,
            tunnel: connections?.tunnel,
            clients: connections?.clientItems ?? [],
            geminiCloud: connections?.geminiCloud,
            installations: management.agent.installationItems,
            providers: management.agent.providerItems,
            setupOperations: management.agent.setupOperations
          )
        ) {
          overview(
            workbench: workbench,
            management: management,
            connections: connections,
            agentReconnectSummary: agentReconnectSummary
          )
        },
        workbench: pageCache.workbench(
          key: WindowsDesktopWorkbenchCacheKey(
            workbench: workbench,
            management: management,
            settings: settings,
            browserAvailable: browserAvailable,
            browserSite: browserSite,
            browserURL: browserURL,
            browserStatus: browserStatus,
            browserCanGoBack: browserCanGoBack,
            browserCanGoForward: browserCanGoForward
          )
        ) {
          workbenchPage(
            workbench,
            management: management,
            browserAvailable: browserAvailable,
            browserSite: browserSite,
            browserURL: browserURL,
            browserStatus: browserStatus,
            browserCanGoBack: browserCanGoBack,
            browserCanGoForward: browserCanGoForward,
            modelRefreshInProgress: modelRefreshInProgress,
            canRefreshModels: canRefreshModels
          )
        },
        projects: pageCache.projects(
          key: WindowsDesktopProjectsCacheKey(
            workbench: workbench,
            management: management,
            workspace: workspace
          )
        ) {
          projectsPage(workbench: workbench, management: management, workspace: workspace)
        },
        logs: pageCache.logs(key: WindowsDesktopLogsCacheKey(logs)) {
          logsPage(logs)
        },
        connections: pageCache.connections(
          key: WindowsDesktopConnectionsCacheKey(
            workbench: workbench,
            management: management,
            connections: connections,
            settings: settings
          )
        ) {
          connectionsPage(
            workbench: workbench,
            management: management,
            connections: connections,
            settings: settings
          )
        },
        settings: pageCache.settings(
          key: WindowsDesktopSettingsCacheKey(
            settings: settings,
            agentDefaults: agentDefaults
          )
        ) {
          settingsPage(settings: settings, agentDefaults: agentDefaults)
        },
        appUpdate: appUpdate
      )
      ConversationPerformanceRecorder.shared.record(
        ConversationPerformanceSample(
          stage: .desktopStateBuild,
          duration: startedAt.duration(to: ContinuousClock.now),
          entryCount: workbench.selectedTaskDetail?.conversation.count ?? 0
        )
      )
      return state
    }

    private static func overview(
      workbench: WindowsWorkbenchDisplay,
      management: WindowsManagementDisplay,
      connections: WindowsConnectionDisplay?,
      agentReconnectSummary: String?
    ) -> BridgeDesktopOverviewState {
      let tunnel = connections?.tunnel
      let clientConnections = BridgeDesktopOverviewPresentation.clientConnections(
        clients: connections?.clientItems ?? [],
        serviceAvailable: workbench.connectionState == .connected,
        localMCPReady: workbench.mcpState == "ready", tunnel: tunnel,
        geminiCloud: connections?.geminiCloud)
      let clientNotices = BridgeDesktopOverviewPresentation.clientNotices(
        connections: clientConnections, serviceAvailable: workbench.connectionState == .connected)
      let agentNotices = management.agent.installationItems.compactMap { installation in
        let desktop = management.agent.providerItems.compactMap(\.desktop).first {
          $0.installationID == installation.installationID
        }
        let availability = BridgeDesktopAgentAvailability.resolve(
          providerID: installation.providerID, enabled: installation.enabled,
          availability: installation.availability, desktop: desktop)
        return BridgeDesktopOverviewPresentation.agentNotice(
          installationID: installation.installationID, providerID: installation.providerID,
          displayName: installation.displayName, availability: installation.availability,
          requiresReconnect: availability == .requiresReconnect)
      }
      let setupNotices = BridgeDesktopOverviewPresentation.setupNotices(
        operations: management.agent.setupOperations)

      return BridgeDesktopOverviewState(
        title: "概览",
        subtitle: "",
        notices: notices(workbench: workbench) + clientNotices + agentNotices + setupNotices,
        metrics: [],
        services: services(
          workbench: workbench,
          management: management,
          tunnel: tunnel,
          agentReconnectSummary: agentReconnectSummary
        ),
        serviceActions: [],
        recentTasks: workbench.recentTasks.prefix(4).map {
          BridgeDesktopRecentTask(
            id: $0.taskID,
            title: $0.title,
            projectName: $0.projectName,
            source: $0.source,
            status: $0.status,
            updatedAt: $0.updatedAt
          )
        },
        lastUpdatedAt: workbench.recentTasks.map(\.updatedAt).max(),
        clientConnections: clientConnections,
        onboardingSteps: BridgeDesktopOverviewPresentation.onboardingSteps(
          hasProjects: !management.project.rows.isEmpty,
          hasConfiguredClient: clientConnections.contains { $0.tone == .success }
            || (connections?.geminiCloud?.enabled == true
              && connections?.geminiCloud?.lifecycle == "configured"
              && connections?.clientItems.contains {
                $0.clientID == "google.gemini" && $0.enabled
              } == true)
        )
      )
    }

    private static func services(
      workbench: WindowsWorkbenchDisplay,
      management: WindowsManagementDisplay,
      tunnel: BridgeDesktopTunnelState?,
      agentReconnectSummary: String?
    ) -> [BridgeDesktopServiceRow] {
      let serviceState = connectionStatePresentation(workbench.connectionState)
      let mcpState = mcpPresentation(for: workbench)
      let available = management.availableAgentCount
      let registered = management.agent.installationRows.count
      return [
        BridgeDesktopServiceRow(
          id: "service",
          title: "后台常驻 Service",
          value: serviceState.label,
          symbol: serviceState.symbol,
          tone: serviceState.tone,
          destination: .connections
        ),
        BridgeDesktopServiceRow(
          id: "local-mcp",
          title: "本地 MCP 通道",
          value: mcpState.label,
          symbol: mcpState.symbol,
          tone: mcpState.tone,
          destination: .connections
        ),
        overviewTunnelRow(tunnel),
        BridgeDesktopServiceRow(
          id: "local-agents",
          title: "本机 Agent 引擎",
          value: agentReconnectSummary ?? "\(available) 个可用 / 共 \(registered) 个",
          symbol: agentReconnectSummary == nil ? "cpu.fill" : "exclamationmark.triangle.fill",
          tone: agentReconnectSummary == nil
            ? (available > 0 ? .success : .neutral)
            : .warning,
          destination: .connections
        ),
      ]
    }

    private static func agentReconnectSummary(
      from management: WindowsManagementDisplay
    ) -> String? {
      ProjectAgentPresentation.reconnectSummary(
        names: management.agent.installationItems.compactMap { installation in
          let desktop = management.agent.providerItems.compactMap(\.desktop).first {
            $0.installationID == installation.installationID
          }
          return BridgeDesktopAgentAvailability.resolve(
            providerID: installation.providerID, enabled: installation.enabled,
            availability: installation.availability, desktop: desktop) == .requiresReconnect
            ? installation.displayName : nil
        }
      )
    }

    private static func mcpPresentation(
      for workbench: WindowsWorkbenchDisplay
    ) -> (label: String, symbol: String, tone: BridgeDesktopStatusTone) {
      guard workbench.connectionState == .connected else {
        let state = connectionStatePresentation(workbench.connectionState)
        return (state.label, state.symbol, state.tone)
      }
      let state = workbench.mcpState.trimmingCharacters(in: .whitespacesAndNewlines)
      guard state == "ready" else {
        return (state.isEmpty ? "未知" : state, "circle.dashed", .neutral)
      }
      return ("ready", "checkmark.circle.fill", .success)
    }

    private static func connectionStatePresentation(
      _ state: WindowsWorkbenchDisplay.ConnectionState
    ) -> (label: String, symbol: String, tone: BridgeDesktopStatusTone) {
      switch state {
      case .idle:
        ("未连接", "circle.dashed", .neutral)
      case .connecting:
        ("连接中…", "circle.dashed", .running)
      case .connected:
        ("已连接", "checkmark.circle.fill", .success)
      case .unavailable:
        ("不可用", "circle.dashed", .error)
      }
    }

    private static func connectionLabel(
      for state: WindowsWorkbenchDisplay.ConnectionState
    ) -> String {
      connectionStatePresentation(state).label
    }

    private static func connectionTone(
      for state: WindowsWorkbenchDisplay.ConnectionState
    ) -> BridgeDesktopStatusTone {
      connectionStatePresentation(state).tone
    }
  }
#endif
