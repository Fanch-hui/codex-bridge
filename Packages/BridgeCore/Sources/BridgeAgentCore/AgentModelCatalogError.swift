import Foundation

public enum AgentModelCatalogError: Error, Equatable, LocalizedError, Sendable {
  case invalidConfiguration
  case missingCredential
  case catalogNotConfigured
  case unavailable
  case http(Int)
  case invalidResponse
  case empty
  case piAzureConfigurationMigrationRequired

  public var code: String {
    switch self {
    case .invalidConfiguration: "agent_model_configuration_invalid"
    case .missingCredential: "agent_model_credential_required"
    case .catalogNotConfigured: "agent_model_catalog_not_configured"
    case .unavailable: "agent_model_catalog_unavailable"
    case .http: "agent_model_catalog_http_error"
    case .invalidResponse: "agent_model_catalog_invalid_response"
    case .empty: "agent_model_catalog_empty"
    case .piAzureConfigurationMigrationRequired: "pi_azure_configuration_migration_required"
    }
  }

  public var requiresConnectionConfiguration: Bool {
    switch self {
    case .invalidConfiguration, .missingCredential, .catalogNotConfigured,
      .piAzureConfigurationMigrationRequired:
      true
    default: false
    }
  }

  public var retryable: Bool {
    switch self {
    case .unavailable: true
    case .http(let status): status == 429 || status >= 500
    default: false
    }
  }

  public var nextAction: String {
    if self == .piAzureConfigurationMigrationRequired {
      return "migrate_pi_native_azure_configuration_and_refresh_models"
    }
    return requiresConnectionConfiguration
      ? "ask_local_user_to_configure_agent_connection"
      : "check_agent_connection_and_retry_model_catalog"
  }

  public var errorDescription: String? {
    switch self {
    case .invalidConfiguration:
      "模型连接配置无效，请在 Bridge 的 Agent 连接设置中检查协议和地址。"
    case .missingCredential:
      "缺少模型目录凭据，请在 Bridge 的 Agent 连接设置中配置 API key。"
    case .catalogNotConfigured:
      "缺少模型目录地址，请在 Bridge 的 Agent 连接设置中配置独立目录地址。"
    case .unavailable:
      "无法连接 Agent 模型目录，请检查目录地址和网络。"
    case .http(let status):
      "Agent 模型目录返回 HTTP \(status)，请检查目录地址、凭据和套餐权限。"
    case .invalidResponse:
      "Agent 模型目录未返回有效的模型列表，请检查目录端点。"
    case .empty:
      "Agent 模型目录返回空列表，请检查连接配置和套餐权限。"
    case .piAzureConfigurationMigrationRequired:
      "Pi 当前目录中没有所选 Azure 模型。请按 Pi 1.0.3 发布说明迁移原生 auth.json、models.json 和 settings.json 中的 provider：azure-openai-responses → azure，并检查对应认证、部署和模型配置。Bridge 默认选择已保留。发布说明：\(PiAzureModelMigration.releaseNotesURL)"
    }
  }
}
