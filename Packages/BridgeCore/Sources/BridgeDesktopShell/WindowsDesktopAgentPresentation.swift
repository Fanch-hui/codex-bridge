#if os(Windows) || os(Linux)
  import BridgeDesktopUI
  import BridgeIPC
  import BridgeServiceAppCore

  enum WindowsDesktopAgentPresentation {
    static func provider(_ provider: IPCAgentProviderSummary) -> BridgeDesktopAgentProviderRow {
      self.provider(provider, desktop: nil)
    }

    static func provider(
      _ provider: IPCAgentProviderSummary,
      desktop: BridgeDesktopDeepSeekHarnessDesktopState?
    ) -> BridgeDesktopAgentProviderRow {
      BridgeDesktopAgentProviderRow(
        providerID: provider.providerID,
        displayName: provider.displayName,
        adapterRevision: provider.adapterRevision,
        discoveryState: provider.discoveryState,
        discoveryMessage: provider.discoveryMessage,
        discoveredExecutablePath: provider.discoveredExecutablePath,
        discoveredConfigurationPath: provider.discoveredConfigurationPath,
        configuredBaseURL: provider.configuredBaseURL,
        configuredInferenceProtocol: provider.configuredInferenceProtocol,
        configuredCatalogBaseURL: provider.configuredCatalogBaseURL,
        requiresConfiguration: provider.requiresConfiguration,
        requiresHeadlessAlwaysProceed: provider.requiresHeadlessAlwaysProceed,
        supportsModelSelection: provider.supportsModelSelection,
        supportsEffortSelection: provider.supportsEffortSelection,
        supportsSteer: provider.supportsSteer,
        supportsWorkspaceWrite: provider.supportsWorkspaceWrite,
        detail: ProjectAgentPresentation.provider(provider).detailText,
        desktop: provider.providerID == "deepseek-harness-desktop" ? desktop : nil
      )
    }

    static func installation(
      _ installation: IPCAgentInstallationSummary,
      canToggle: Bool,
      canReprobe: Bool,
      canRemove: Bool
    ) -> BridgeDesktopAgentInstallationRow {
      BridgeDesktopAgentInstallationRow(
        installationID: installation.installationID,
        providerID: installation.providerID,
        displayName: installation.displayName,
        distribution: installation.distribution,
        executablePath: installation.executablePath,
        version: installation.version,
        protocolRevision: installation.protocolRevision,
        adapterRevision: installation.adapterRevision,
        trustProfile: installation.trustProfile,
        securityProfileID: installation.securityProfileID,
        enabled: installation.isEnabled,
        isActive: installation.isActive,
        availability: installation.availability,
        effectiveCapabilities: installation.effectiveCapabilities,
        nativeSessionOperations: installation.nativeSessionOperations,
        lastProbeError: installation.lastProbeError,
        lastProbedAt: installation.lastProbedAt,
        updatedAt: installation.updatedAt,
        canToggle: canToggle,
        canReprobe: canReprobe,
        canRemove: canRemove
      )
    }

    static func model(_ model: IPCAgentModelSummary) -> BridgeDesktopModelOption {
      BridgeDesktopModelOption(
        modelID: model.modelID,
        displayName: model.displayName,
        reasoningEfforts: model.supportedReasoningEfforts.map {
          BridgeDesktopChoice(id: $0, title: DirectWorkspacePresentation.effortLabel($0))
        },
        defaultReasoningEffort: model.defaultReasoningEffort,
        reasoningCapabilitiesAvailable: model.reasoningCapabilitiesAvailable,
        isDefaultModel: model.isDefaultModel
      )
    }
  }

  extension WindowsAgentDefaultsModel {
    nonisolated static func permissionValues(for providerID: String?) -> [String] {
      BridgeDesktopPresentation.agentPermissionOptions(for: providerID).map(\.id)
    }
  }
#endif
