import BridgeAgentCore
import BridgeCodexService
import BridgeDeepSeekHarnessACP
import BridgeIPC
import BridgeMCP
import BridgeServiceApplication
import BridgeServiceCore
import BridgeTunnel
import Foundation

extension BridgeServiceRequestController {
  static func map(_ error: Error) -> BridgeServiceIPCError {
    if error is BridgeServiceIPCCodecError {
      return .init(code: "invalid_request", message: "The XPC request is invalid.")
    }
    if let error = error as? ServiceLocalMCPError {
      return mapLocalMCPError(error)
    }
    if error is ServiceCodexExecutableError {
      return .init(
        code: "codex_executable_invalid",
        message:
          "The selected file is not a usable Codex executable. Choose codex.exe, or the npm codex.cmd shim."
      )
    }
    if let error = error as? ServiceMCPClientRegistryError {
      return mapMCPClientRegistryError(error)
    }
    if let error = error as? ServiceAgentRegistryError {
      return mapAgentRegistryError(error)
    }
    if let error = error as? ServiceAgentConnectionError {
      switch error {
      case .installationNotFound:
        return .init(code: "agent_installation_not_found", message: error.localizedDescription)
      case .headlessPermissionConfirmationRequired:
        return .init(
          code: "agent_headless_permission_confirmation_required",
          message: error.localizedDescription
        )
      }
    }
    if let error = error as? ServiceAgentCredentialError {
      return mapAgentCredentialError(error)
    }
    if let error = error as? ServiceDeepSeekHarnessMCPError {
      return mapDeepSeekHarnessMCPError(error)
    }
    if let error = error as? AgentNativePermissionPolicyError {
      return mapAgentNativePermissionPolicyError(error)
    }
    if let error = error as? DeepSeekHarnessModelCatalogError {
      return .init(
        code: "agent_model_catalog_failed", message: error.localizedDescription, retryable: true)
    }
    if let error = error as? DeepSeekHarnessACPError {
      return mapDeepSeekHarnessError(error)
    }
    if let error = error as? ServiceStoreError {
      return mapStoreError(error)
    }
    if let error = error as? BridgeMCPQueryError {
      return mapMCPQueryError(error)
    }
    if error is TunnelConfigurationError {
      return .init(
        code: "invalid_tunnel_configuration",
        message: "The Tunnel configuration is invalid."
      )
    }
    if let error = error as? ServiceTunnelError {
      return mapTunnelError(error)
    }
    if error is ExecutionServiceError {
      return .init(
        code: "execution_failed",
        message: "The provider operation failed.",
        retryable: true
      )
    }
    return .init(
      code: "internal_error",
      message: "The service operation failed.",
      retryable: true
    )
  }

  private static func mapLocalMCPError(_ error: ServiceLocalMCPError) -> BridgeServiceIPCError {
    switch error {
    case .localPortUnavailable:
      return .init(
        code: "local_port_unavailable",
        message: "The configured local MCP port is unavailable.",
        retryable: true
      )
    case .endpointManagedByConfiguration:
      return .init(
        code: "endpoint_managed_by_configuration",
        message: "The local MCP endpoint is managed by the service configuration."
      )
    }
  }

  private static func mapMCPClientRegistryError(
    _ error: ServiceMCPClientRegistryError
  ) -> BridgeServiceIPCError {
    switch error {
    case .unsupportedClient:
      return .init(code: "invalid_client", message: "The MCP client is unsupported.")
    case .clientDisabled:
      return .init(code: "client_disabled", message: "The MCP client is disabled.")
    }
  }

  private static func mapAgentRegistryError(
    _ error: ServiceAgentRegistryError
  ) -> BridgeServiceIPCError {
    switch error {
    case .providerUnavailable:
      return .init(
        code: "agent_provider_unavailable",
        message: "The Agent Provider adapter is unavailable."
      )
    case .installationUnavailable:
      return .init(
        code: "agent_installation_unavailable",
        message: "The Agent installation must pass Probe before it can be enabled."
      )
    case .installationNeedsReview:
      return .init(
        code: "agent_installation_needs_review",
        message: "The Agent executable changed and requires explicit local review."
      )
    case .connectionProbeFailed:
      return .init(
        code: "agent_connection_probe_failed",
        message: "The Agent installation did not pass the connection Probe."
      )
    case .replacementProbeFailed(_, let reason):
      return .init(code: "agent_connection_probe_failed", message: reason)
    case .registrationInProgress:
      return .init(
        code: "agent_registration_in_progress",
        message: "This Agent executable is already being registered.",
        retryable: true
      )
    }
  }

  private static func mapAgentCredentialError(
    _ error: ServiceAgentCredentialError
  ) -> BridgeServiceIPCError {
    switch error {
    case .unsupportedProvider:
      return .init(
        code: "agent_credentials_unsupported",
        message: "The Agent Provider does not accept connection credentials."
      )
    case .invalidBaseURL:
      return .init(
        code: "agent_base_url_invalid",
        message: "The Agent Base URL is invalid."
      )
    case .invalidAPIKey:
      return .init(
        code: "agent_api_key_invalid",
        message: "The Agent API key is invalid."
      )
    case .invalidConfigurationPath:
      return .init(
        code: "agent_configuration_invalid",
        message: "The Agent configuration path is invalid."
      )
    case .invalidStoredAPIKey:
      return .init(
        code: "agent_credentials_unavailable",
        message: "The stored Agent credentials are unavailable."
      )
    }
  }

  private static func mapAgentNativePermissionPolicyError(
    _ error: AgentNativePermissionPolicyError
  ) -> BridgeServiceIPCError {
    switch error {
    case .unavailable:
      return .init(
        code: "agent_native_permissions_unavailable",
        message: "Native permission settings are unavailable for this Agent installation."
      )
    case .revisionConflict:
      return .init(
        code: "agent_permission_revision_conflict",
        message: "The native permission settings changed. Reload them before saving.",
        retryable: true
      )
    case .settingsInvalid:
      return .init(
        code: "agent_permission_settings_invalid",
        message: "The native permission settings file is invalid."
      )
    case .settingsUnsafe:
      return .init(
        code: "agent_permission_settings_unsafe",
        message: "The native permission settings file cannot be modified safely."
      )
    case .ruleInvalid:
      return .init(
        code: "agent_permission_rule_invalid",
        message: "The native permission rule is invalid."
      )
    case .remediationUnavailable:
      return .init(
        code: "agent_permission_remediation_unavailable",
        message: "A safe native permission rule could not be derived for this tool call."
      )
    }
  }

  private static func mapDeepSeekHarnessMCPError(
    _ error: ServiceDeepSeekHarnessMCPError
  ) -> BridgeServiceIPCError {
    switch error {
    case .serverNotFound:
      return .init(code: "dsh_mcp_server_not_found", message: error.localizedDescription)
    case .secretStoreUnavailable, .invalidStoredSecret:
      return .init(code: "dsh_mcp_credentials_unavailable", message: error.localizedDescription)
    }
  }

  private static func mapDeepSeekHarnessError(
    _ error: DeepSeekHarnessACPError
  ) -> BridgeServiceIPCError {
    switch error {
    case .artifactInvalid(let field):
      return .init(
        code: "agent_artifact_invalid",
        message:
          "The selected DeepSeek Harness build is incomplete or incompatible (\(field)). Select the built apps/cli/lib/bin.js entry, or packages/examples/acp-demo/lib/bin.js for an ACP demo build."
      )
    case .templateMismatch:
      return .init(
        code: "agent_configuration_mismatch",
        message:
          "The selected cordis.yml must retain the Codex Bridge read-only profile structure. Only the model catalog, default model, thinking mode, and reasoning effort may differ."
      )
    case .nodeVersionIncompatible:
      return .init(
        code: "agent_runtime_incompatible",
        message: "DeepSeek Harness requires Node ^22.19.0 or >=24.0.0."
      )
    case .processUnavailable:
      return .init(
        code: "agent_runtime_unavailable",
        message: "The DeepSeek Harness Node runtime could not be launched."
      )
    case .processExited:
      return .init(
        code: "agent_runtime_probe_failed",
        message: "The DeepSeek Harness Node version probe failed."
      )
    default:
      return .init(
        code: "agent_validation_failed",
        message: "The DeepSeek Harness installation could not be validated."
      )
    }
  }

  private static func mapStoreError(_ error: ServiceStoreError) -> BridgeServiceIPCError {
    switch error {
    case .unknownProject:
      return .init(code: "project_not_found", message: "The project is unavailable.")
    case .unknownTask:
      return .init(code: "task_not_found", message: "The task is unavailable.")
    case .unknownAgentInstallation:
      return .init(
        code: "agent_installation_not_found",
        message: "The Agent installation is unavailable."
      )
    case .duplicateAgentInstallation, .duplicateAgentExecutable:
      return .init(
        code: "duplicate_agent_installation",
        message: "The Agent executable is already registered."
      )
    case .activeWriteTaskExists:
      return .init(
        code: "busy",
        message: "The project already has an active write task.",
        retryable: true
      )
    case .idempotencyConflict, .duplicateTask:
      return .init(
        code: "idempotency_conflict",
        message: "The request identifier is already in use."
      )
    case .invalidArgument, .invalidTaskTransition, .immutableTaskChanged:
      return .init(
        code: "invalid_state",
        message: "The operation is invalid for the current state."
      )
    case .duplicateProject, .duplicateProjectRoot:
      return .init(
        code: "duplicate_project",
        message: "The project root is already registered."
      )
    case .corruptSchema, .corruptRecord, .unsupportedSchemaVersion, .storageFailure:
      return .init(
        code: "unavailable",
        message: "The local service store is unavailable.",
        retryable: true
      )
    case .storageBusy:
      return .init(
        code: "busy",
        message: "The service database is busy; please retry shortly.",
        retryable: true
      )
    }
  }

  private static func mapTunnelError(_ error: ServiceTunnelError) -> BridgeServiceIPCError {
    switch error {
    case .invalidRuntimeKey, .invalidStoredConfiguration:
      return .init(code: "invalid_tunnel_configuration", message: error.localizedDescription)
    case .notConfigured:
      return .init(code: "tunnel_not_configured", message: error.localizedDescription)
    case .helperUnavailable:
      return .init(code: "tunnel_helper_unavailable", message: error.localizedDescription)
    case .secretStoreUnavailable:
      return .init(code: "keychain_unavailable", message: error.localizedDescription)
    case .localMCPUnavailable, .serviceStopped, .startFailed:
      return .init(
        code: "tunnel_unavailable",
        message: error.localizedDescription,
        retryable: true
      )
    }
  }
}
