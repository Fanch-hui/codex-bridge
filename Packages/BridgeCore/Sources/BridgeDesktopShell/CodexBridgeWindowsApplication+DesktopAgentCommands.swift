#if os(Windows) || os(Linux)
  import BridgeDesktopUI
  import BridgeIPC
  import BridgeServiceAppCore

  extension CodexBridgeDesktopApplication {
    static func runDesktopAgentCommand(
      _ envelope: BridgeDesktopCommandEnvelope,
      management: WindowsManagementModel,
      auxiliary: WindowsAuxiliaryRuntime
    ) -> Bool {
      let payload = envelope.payload
      switch envelope.command {
      case .beginAgentSetup, .refreshAgentSetups, .continueAgentSetup, .cancelAgentSetup,
        .openAgentSetupLogin:
        Task { @MainActor in
          if await management.handleAgentSetupCommand(envelope) {
            await auxiliary.agentDefaults.refresh()
          }
        }
      case .connectAgent:
        return connectAgent(payload, management: management, auxiliary: auxiliary)
      case .registerAgent:
        return registerAgentInput(payload, management: management, auxiliary: auxiliary)
      case .beginAgentRegistration:
        return beginAgentRegistration(payload, management: management)
      case .saveQoderRuntimeSettings:
        guard
          let distribution = BridgeDesktopCommandValue.qoderDistribution(
            payload.qoderDistribution
          )
        else { return true }
        let request = IPCAgentQoderRuntimeSettingsRequest(
          distribution: distribution,
          activeInstallationID: BridgeDesktopCommandValue.nonEmpty(payload.installationID),
          nodeExecutablePath: payload.nodeExecutablePath,
          sdkRoot: payload.sdkRoot
        )
        Task { @MainActor in await management.setQoderRuntimeSettings(request) }
      case .selectAgent:
        let requestedID = BridgeDesktopCommandValue.nonEmpty(
          payload.installationID ?? payload.providerID)
        guard let requestedID else { return true }
        if let index = management.agentInstallations.firstIndex(where: {
          $0.installationID == requestedID
        }) {
          management.selectInstallation(at: index)
        } else if let index = management.agentProviders.firstIndex(where: {
          $0.providerID == requestedID
        }) {
          management.selectProvider(at: index)
        }
      case .setAgentEnabled:
        guard let installationID = BridgeDesktopCommandValue.nonEmpty(payload.installationID),
          let enabled = payload.enabled,
          let index = management.agentInstallations.firstIndex(where: {
            $0.installationID == installationID
          })
        else { return true }
        management.selectInstallation(at: index)
        Task { @MainActor in
          await management.setSelectedAgentEnabled(enabled, installationID: installationID)
          await auxiliary.agentDefaults.refresh()
        }
      case .reprobeAgent:
        guard let installationID = BridgeDesktopCommandValue.nonEmpty(payload.installationID),
          let index = management.agentInstallations.firstIndex(where: {
            $0.installationID == installationID
          })
        else { return true }
        management.selectInstallation(at: index)
        Task { @MainActor in
          await management.reprobeSelectedAgent(
            acceptReplacement: payload.acceptReplacement ?? false,
            installationID: installationID
          )
          await auxiliary.agentDefaults.refresh()
        }
      case .removeAgent:
        guard let installationID = BridgeDesktopCommandValue.nonEmpty(payload.installationID),
          let index = management.agentInstallations.firstIndex(where: {
            $0.installationID == installationID
          })
        else { return true }
        management.selectInstallation(at: index)
        Task { @MainActor in
          await management.removeSelectedAgent(installationID: installationID)
          await auxiliary.agentDefaults.refresh()
        }
      case .refreshAgentModels:
        guard let providerID = BridgeDesktopCommandValue.nonEmpty(payload.providerID),
          let installationID = BridgeDesktopCommandValue.nonEmpty(payload.installationID)
        else { return true }
        Task { @MainActor in
          await auxiliary.agentDefaults.refreshModels(
            providerID: providerID,
            installationID: installationID,
            forceRefresh: true
          )
        }
      case .saveAgentDefault:
        guard let providerID = BridgeDesktopCommandValue.nonEmpty(payload.providerID),
          let permissionMode = BridgeDesktopCommandValue.nonEmpty(payload.permissionMode)
        else { return true }
        Task { @MainActor in
          await auxiliary.agentDefaults.saveDefaults(
            providerID: providerID,
            installationID: BridgeDesktopCommandValue.nonEmpty(payload.installationID),
            model: BridgeDesktopCommandValue.nonEmpty(payload.modelID),
            permissionMode: permissionMode,
            effort: BridgeDesktopCommandValue.nonEmpty(payload.effort) ?? ""
          )
        }
      default:
        return false
      }
      return true
    }

    static func registerAgentFromDesktop(
      providerID: String,
      displayName: String,
      executablePath: String,
      configurationPath: String?,
      qoderDistribution: String?,
      management: WindowsManagementModel,
      auxiliary: WindowsAuxiliaryRuntime
    ) -> Bool {
      Task { @MainActor in
        await management.registerAgent(
          providerID: providerID,
          executablePath: executablePath,
          configurationPath: configurationPath ?? "",
          displayName: displayName,
          qoderDistribution: qoderDistribution
        )
        await auxiliary.agentDefaults.refresh()
      }
      return true
    }

    private static func connectAgent(
      _ payload: BridgeDesktopCommandPayload,
      management: WindowsManagementModel,
      auxiliary: WindowsAuxiliaryRuntime
    ) -> Bool {
      guard let providerID = BridgeDesktopCommandValue.nonEmpty(payload.providerID) else {
        return true
      }
      let distribution = BridgeDesktopCommandValue.qoderDistribution(payload.qoderDistribution)
      guard providerID != "qoder" || distribution != nil else { return true }
      Task { @MainActor in
        await management.connectAgent(
          providerID: providerID,
          baseURL: AgentConnectionInput.baseURL(payload.baseURL),
          apiKey: AgentConnectionInput.apiKey(payload.apiKey),
          alwaysProceedConfirmed: payload.confirmed == true,
          qoderDistribution: distribution,
          installationID: providerID == "qoder"
            ? BridgeDesktopCommandValue.nonEmpty(payload.installationID) : nil,
          inferenceProtocol: payload.inferenceProtocol,
          catalogBaseURL: AgentConnectionInput.baseURL(payload.catalogBaseURL)
        )
        await auxiliary.agentDefaults.refresh()
      }
      return true
    }

    private static func registerAgentInput(
      _ payload: BridgeDesktopCommandPayload,
      management: WindowsManagementModel,
      auxiliary: WindowsAuxiliaryRuntime
    ) -> Bool {
      guard let providerID = BridgeDesktopCommandValue.nonEmpty(payload.providerID),
        let executablePath = BridgeDesktopCommandValue.nonEmpty(payload.executable),
        let displayName = BridgeDesktopCommandValue.nonEmpty(payload.displayName)
          ?? BridgeDesktopCommandValue.nonEmpty(payload.name)
      else { return true }
      let distribution = BridgeDesktopCommandValue.qoderDistribution(payload.qoderDistribution)
      guard providerID != "qoder" || distribution != nil else { return true }
      return registerAgentFromDesktop(
        providerID: providerID,
        displayName: displayName,
        executablePath: executablePath,
        configurationPath: BridgeDesktopCommandValue.nonEmpty(payload.configurationPath),
        qoderDistribution: distribution,
        management: management,
        auxiliary: auxiliary
      )
    }

    private static func beginAgentRegistration(
      _ payload: BridgeDesktopCommandPayload,
      management: WindowsManagementModel
    ) -> Bool {
      let providerID = BridgeDesktopCommandValue.nonEmpty(payload.providerID)
      let distribution = BridgeDesktopCommandValue.qoderDistribution(payload.qoderDistribution)
      guard providerID != "qoder" || distribution != nil else { return true }
      let provider =
        providerID.flatMap { id in
          management.agentProviders.first { $0.providerID == id }
        } ?? management.agentProviders.first
      guard let provider else { return true }
      let title =
        provider.providerID == "opencode"
        ? "选择 OpenCode 命令行工具"
        : "选择 \(provider.displayName) 命令行可执行文件"
      DesktopPlatformHost.chooseExecutableFile(title: title) { executablePath in
        if provider.requiresConfiguration {
          DesktopPlatformHost.chooseConfigFile(
            title: "选择 \(provider.displayName) 配置文件 (cordis.yml)"
          ) { configurationPath in
            enqueueAgentRegistration(
              provider: provider,
              executablePath: executablePath,
              configurationPath: configurationPath,
              qoderDistribution: distribution
            )
          }
        } else {
          enqueueAgentRegistration(
            provider: provider,
            executablePath: executablePath,
            configurationPath: nil,
            qoderDistribution: distribution
          )
        }
      }
      return true
    }

    nonisolated private static func enqueueAgentRegistration(
      provider: IPCAgentProviderSummary,
      executablePath: String,
      configurationPath: String?,
      qoderDistribution: String?
    ) {
      DesktopPlatformHost.enqueueCommand(
        .registerAgentFromDesktop(
          providerID: provider.providerID,
          displayName: provider.displayName,
          executablePath: executablePath,
          configurationPath: configurationPath,
          qoderDistribution: qoderDistribution
        ))
    }
  }
#endif
