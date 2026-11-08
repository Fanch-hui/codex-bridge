import BridgeACP
import BridgeAgentCore

extension ClaudeSDKProvider {
  static func capabilities(
    models: [AgentModelDescriptor], metadata: ACPJSONValue,
    request: AgentExecutionRequest? = nil
  ) -> AgentCapabilitySnapshot {
    let tools = Set(metadata["nativeTools"]?.arrayValue?.compactMap(\.stringValue) ?? [])
    let native = Set(metadata["nativeCapabilities"]?.arrayValue?.compactMap(\.stringValue) ?? [])
    let methods = Set(metadata["queryMethods"]?.arrayValue?.compactMap(\.stringValue) ?? [])
    var values: Set<AgentCapability> = [.sessionCreate, .textDelta]
    if native.contains("stream_input_v1") { values.insert(.steer) }
    if native.contains("session_resume_v1") { values.insert(.sessionContinue) }
    if methods.contains("interrupt") {
      values.insert(.interrupt)
      if native.contains("stream_input_v1") { values.insert(.steerInterruptAndContinue) }
    }
    if !tools.isDisjoint(with: ["Read", "Glob", "Grep"]) {
      values.insert(.workspaceRead)
      if native.contains("read_only_v1") { values.insert(.readOnlyExecution) }
    }
    if request == nil || request?.mutationIntent == .workspaceWrite,
      !tools.isDisjoint(with: ["Write", "Edit", "NotebookEdit"]),
      native.contains("approval_v1")
    {
      values.insert(.workspaceWriteInPlace)
    }
    if !tools.isEmpty { values.insert(.toolLifecycle) }
    if native.contains("approval_v1") {
      values.formUnion([.oneShotApproval, .sessionRuleApproval, .structuredApprovalPayload])
    }
    if native.contains("questions_v1") { values.insert(.structuredUserInput) }
    if native.contains("reasoning_v1") { values.insert(.reasoningDelta) }
    if native.contains("usage_v1") { values.insert(.usage) }
    if native.contains("selected_skills_v1") { values.insert(.skills) }
    if native.contains("mcp_v1") { values.insert(.mcpClient) }
    if !models.isEmpty || methods.contains("supportedModels") { values.insert(.modelSelection) }
    if methods.contains("supportedModels")
      || models.contains(where: { !$0.supportedReasoningEfforts.isEmpty })
    {
      values.insert(.effortSelection)
    }
    if request == nil || request?.networkAccessRequested == true {
      if tools.contains("Bash") { values.insert(.shell) }
      if tools.contains("WebSearch") { values.insert(.webSearch) }
      if tools.contains("WebFetch") { values.insert(.webFetch) }
    }
    return AgentCapabilitySnapshot(advertised: values, observed: values, enforced: values)
  }
}
