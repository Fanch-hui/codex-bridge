import Foundation

public enum AgentModelCatalogError: Error, Equatable, LocalizedError, Sendable {
  case invalidConfiguration
  case missingCredential
  case catalogNotConfigured
  case unavailable
  case http(Int)
  case invalidResponse
  case empty

  public var code: String {
    switch self {
    case .invalidConfiguration: "agent_model_configuration_invalid"
    case .missingCredential: "agent_model_credential_required"
    case .catalogNotConfigured: "agent_model_catalog_not_configured"
    case .unavailable: "agent_model_catalog_unavailable"
    case .http: "agent_model_catalog_http_error"
    case .invalidResponse: "agent_model_catalog_invalid_response"
    case .empty: "agent_model_catalog_empty"
    }
  }

  public var requiresConnectionConfiguration: Bool {
    switch self {
    case .invalidConfiguration, .missingCredential, .catalogNotConfigured: true
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
    requiresConnectionConfiguration
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
    }
  }
}
