#if os(Windows)
  import BridgeDesktopUI
  import BridgeIPC
  import BridgeServiceAppCore

  enum WindowsDesktopAgentPresentation {
    static func provider(_ provider: IPCAgentProviderSummary) -> BridgeDesktopAgentProviderRow {
      BridgeDesktopAgentProviderRow(
        providerID: provider.providerID,
        displayName: provider.displayName,
        adapterRevision: provider.adapterRevision,
        requiresConfiguration: provider.requiresConfiguration,
        supportsModelSelection: provider.supportsModelSelection,
        supportsEffortSelection: provider.supportsEffortSelection,
        supportsSteer: provider.supportsSteer,
        supportsWorkspaceWrite: provider.supportsWorkspaceWrite,
        supportsSupervisor: false,
        detail: ProjectAgentPresentation.provider(provider).detailText
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
        executablePath: installation.executablePath,
        version: installation.version,
        protocolRevision: installation.protocolRevision,
        adapterRevision: installation.adapterRevision,
        trustProfile: installation.trustProfile,
        securityProfileID: installation.securityProfileID,
        enabled: installation.isEnabled,
        availability: installation.availability,
        effectiveCapabilities: installation.effectiveCapabilities,
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
        }
      )
    }
  }

  extension WindowsAgentDefaultsModel {
    nonisolated static func permissionValues(for providerID: String?) -> [String] {
      BridgeDesktopPresentation.agentPermissionOptions(for: providerID).map(\.id)
    }
  }
#endif
