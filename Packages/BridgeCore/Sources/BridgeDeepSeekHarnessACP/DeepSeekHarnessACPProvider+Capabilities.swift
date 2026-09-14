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
