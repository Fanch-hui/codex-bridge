import BridgeAgentCore

extension DeepSeekHarnessACPProvider {
  static func capabilities(executablePath: String) -> AgentCapabilitySnapshot {
    guard DeepSeekHarnessACPModernLaunch.isModernEntry(executablePath) else {
      return capabilitySnapshot
    }
    let presentation: Set<AgentCapability> = [.reasoningDelta, .usage]
    return AgentCapabilitySnapshot(
      advertised: capabilitySnapshot.advertised.union(presentation),
      observed: capabilitySnapshot.observed.union(presentation),
      enforced: capabilitySnapshot.enforced.union(presentation)
    )
  }

  static func capabilities(
    executablePath: String,
    initialization: DeepSeekHarnessACPInitialization,
    persistenceAvailable: Bool = true
  ) -> AgentCapabilitySnapshot {
    var snapshot = capabilities(executablePath: executablePath)
    guard DeepSeekHarnessACPModernLaunch.isModernEntry(executablePath) else {
      return snapshot
    }
    var dynamic: Set<AgentCapability> = []
    if persistenceAvailable && initialization.supportsResumeSession {
      dynamic.insert(.sessionContinue)
    }
    if initialization.supportsMCPHTTP {
      dynamic.insert(.mcpClient)
    }
    guard !dynamic.isEmpty else { return snapshot }
    snapshot = AgentCapabilitySnapshot(
      advertised: snapshot.advertised.union(dynamic),
      observed: snapshot.observed.union(dynamic),
      enforced: snapshot.enforced.union(dynamic)
    )
    return snapshot
  }

  public static let capabilitySnapshot = AgentCapabilitySnapshot(
    advertised: [
      .sessionCreate,
      .interrupt,
      .steer,
      .steerInterruptAndContinue,
      .textDelta,
      .toolLifecycle,
      .workspaceRead,
      .workspaceWriteInPlace,
      .oneShotApproval,
      .structuredApprovalPayload,
      .modelSelection,
      .effortSelection,
      .shell,
      .webSearch,
      .webFetch,
      .codeExecution,
      .subagents,
      .workflow,
      .skills,
    ],
    observed: [
      .sessionCreate,
      .interrupt,
      .steer,
      .steerInterruptAndContinue,
      .textDelta,
      .toolLifecycle,
      .workspaceRead,
      .workspaceWriteInPlace,
      .oneShotApproval,
      .structuredApprovalPayload,
      .modelSelection,
      .effortSelection,
      .shell,
      .webSearch,
      .webFetch,
      .codeExecution,
      .subagents,
      .workflow,
      .skills,
    ],
    enforced: [
      .sessionCreate,
      .interrupt,
      .steer,
      .steerInterruptAndContinue,
      .textDelta,
      .toolLifecycle,
      .workspaceRead,
      .workspaceWriteInPlace,
      .oneShotApproval,
      .structuredApprovalPayload,
      .modelSelection,
      .effortSelection,
      .shell,
      .webSearch,
      .webFetch,
      .codeExecution,
      .subagents,
      .workflow,
      .skills,
    ]
  )
}
