import BridgeAgentCore
import BridgeSecurity
import BridgeServiceApplication
import Foundation

enum ServiceAgentSetupErrorPresentation {
  static func present(_ error: any Error, providerID: AgentProviderID) -> any Error {
    if error is ServiceAgentSetupError { return error }
    if let catalog = error as? AgentModelCatalogError {
      switch catalog {
      case .missingCredential, .invalidConfiguration, .catalogNotConfigured,
        .piAzureConfigurationMigrationRequired, .http(401), .http(403):
        return ServiceAgentSetupError.userAction(catalog.localizedDescription)
      default:
        return catalog
      }
    }
    if let credential = error as? ServiceAgentCredentialError {
      return ServiceAgentSetupError.userAction(credential.localizedDescription)
    }
    if let storage = error as? SecretStoreError {
      let detail: String
      if case .keychainFailure(let status) = storage {
        detail = "（系统错误 \(status)）"
      } else {
        detail = ""
      }
      return ServiceAgentSetupError.unavailable(
        "无法访问系统凭据存储\(detail)，请检查系统授权后重新验证。")
    }
    // DSH Probe already supplies a sanitized failure reason. Its text must not
    // turn a network, runtime or system-access failure into a credential prompt.
    guard providerID != .deepSeekHarness else { return error }
    let message = error.localizedDescription
    let text = (message + " " + String(describing: error)).lowercased()
    if ["auth", "credential", "api key", "login", "未登录", "unauthorized", "model_not_configured"]
      .contains(where: text.contains)
    {
      return ServiceAgentSetupError.userAction(message + " 请完成原生登录或 API 配置后重新验证。")
    }
    return error
  }
}
