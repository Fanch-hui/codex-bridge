import BridgeAgentCore

extension ServiceAgentProviderPolicyRegistry {
  public static let deepSeekHarnessDesktop = ServiceAgentProviderPolicy(
    providerID: .deepSeekHarnessDesktop,
    displayName: "DSH 桌面",
    supportsWorkspaceWrite: true,
    supportsSessionContinuation: true,
    supportsInteractiveApproval: true,
    supportsModelSelection: true,
    supportsEffortSelection: true,
    allowsNetworkAccess: true,
    workspaceEnforcement: "provider_native",
    approvalEnforcement: "local_app",
    networkEnforcement: "provider_native",
    allowedCapabilities: [
      .sessionCreate, .sessionContinue, .interrupt, .textDelta, .reasoningDelta, .toolLifecycle,
      .usage, .oneShotApproval, .structuredUserInput, .workspaceRead, .workspaceWriteInPlace,
      .modelSelection, .effortSelection,
    ],
    requiredArtifactRoles: [.nodeInterpreter],
    requiredProtocolRevision: "codex-bridge-dsh/1",
    registrationTrustProfile: .userTrusted,
    requiresExactRegistrationProfile: true,
    selectionsRequireObservedCapabilities: true
  )
}
