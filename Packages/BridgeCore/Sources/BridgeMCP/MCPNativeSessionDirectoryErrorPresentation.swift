import BridgeAgentCore

extension AgentNativeSessionDirectoryError {
  var nativeSessionToolError: MCPToolErrorDTO {
    let code: String
    let category: MCPToolErrorCategory
    let retryable: Bool
    let nextAction: String
    switch self {
    case .unsupported:
      code = "agent_history_unsupported"
      category = .capabilityUnavailable
      retryable = false
      nextAction = "use_list_tasks_and_get_task"
    case .unavailable:
      code = "agent_history_unavailable"
      category = .infrastructureFailure
      retryable = true
      nextAction = "check_agent_installation_and_retry"
    case .sessionNotFound:
      code = "agent_session_not_found"
      category = .callerError
      retryable = false
      nextAction = "list_agent_native_sessions"
    case .invalidRequest:
      code = "invalid_arguments"
      category = .callerError
      retryable = false
      nextAction = "fix_tool_arguments"
    case .activeSession:
      code = "agent_session_active"
      category = .stateConflict
      retryable = true
      nextAction = "wait_for_task_completion"
    case .scopeMismatch:
      code = "agent_session_scope_mismatch"
      category = .policyDenied
      retryable = false
      nextAction = "choose_session_from_current_project_and_installation"
    case .runtimeFailure:
      code = "agent_history_failed"
      category = .infrastructureFailure
      retryable = true
      nextAction = "check_agent_runtime_and_retry"
    }
    return MCPToolErrorDTO(
      code: code,
      category: category,
      message: errorDescription ?? "The native session operation failed.",
      retryable: retryable,
      nextAction: nextAction)
  }
}
