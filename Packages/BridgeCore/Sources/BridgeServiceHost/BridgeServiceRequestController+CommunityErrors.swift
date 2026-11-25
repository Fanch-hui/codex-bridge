import BridgeIPC
import BridgeProviderRuntime
import BridgeSecurity
import BridgeServiceGateway
import Foundation

extension BridgeServiceRequestController {
  static func mapCommunityProviderError(_ error: Error) -> BridgeServiceIPCError? {
    let code: String
    switch error {
    case let error as ServiceCommunityProviderError:
      switch error {
      case .busy:
        return .init(
          code: "community_provider_busy", message: error.localizedDescription, retryable: true)
      case .invalidRequest: code = "community_provider_invalid_request"
      case .invalidStoredConfiguration: code = "community_provider_invalid_configuration"
      case .pluginMissing: code = "community_provider_missing"
      case .duplicatePlugin: code = "community_provider_already_installed"
      case .conflictingProvider: code = "community_provider_conflict"
      case .incompatible: code = "community_provider_incompatible"
      case .unavailableAuthentication: code = "community_provider_auth_unavailable"
      case .stopped: code = "community_provider_stopped"
      case .unsupportedProtocol: code = "community_provider_protocol_unsupported"
      case .modelUnavailable: code = "community_provider_model_unavailable"
      }
    case let error as ProviderRuntimeError:
      switch error {
      case .busy:
        return .init(
          code: "community_provider_busy", message: error.localizedDescription, retryable: true)
      case .closed:
        return .init(
          code: "community_provider_closed", message: error.localizedDescription, retryable: true)
      case .timedOut:
        return .init(
          code: "community_provider_timeout", message: error.localizedDescription, retryable: true)
      case .invalidMessage: code = "community_provider_invalid_response"
      case .remote: code = "community_provider_failed"
      case .processTreeStillRunning: code = "community_provider_stopped"
      }
    case let error as CommunityProviderInstallationError:
      switch error {
      case .busy:
        return .init(
          code: "community_provider_busy", message: error.localizedDescription, retryable: true)
      case .invalidDirectory: code = "community_provider_invalid_directory"
      case .unavailable: code = "community_provider_installer_unavailable"
      case .processStillRunning: code = "community_provider_stopped"
      case .failed: code = "community_provider_install_failed"
      }
    default:
      return nil
    }
    let message = OutboundContentSecurity.redactedSecrets(
      error.localizedDescription, maximumUTF8Bytes: 2048)
    return .init(code: code, message: message, retryable: false)
  }
}
