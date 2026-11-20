import BridgeACP
import Foundation

enum ServiceCommunityRequestCompatibility: Sendable {
  case qoder
  case cursor
  case devin
  case trae
  case commandCode
  case loomy
  case accio
  case monkeycode
  case autoclaw
  case kiro
  case muse
  case standard

  func adaptOriginal(_ body: Data, source: String, supportsSampling: Bool? = nil) throws -> (
    body: Data, warnings: [String]
  ) {
    let textOnly = self == .kiro
    guard textOnly || supportsSampling == false else { return (body, []) }
    guard var request = try JSONDecoder().decode(ACPJSONValue.self, from: body).objectValue else {
      throw ServiceGatewayRequestError.unsupported("模型请求格式无效。")
    }
    var managed = ["temperature", "top_p"]
    if textOnly {
      switch source {
      case "chat": managed += ["max_tokens", "max_completion_tokens"]
      case "responses": managed.append("max_output_tokens")
      default: throw ServiceGatewayRequestError.unsupported("Kiro 暂只支持纯文本 Chat 和 Responses 对话。")
      }
      if let first = request["max_tokens"]?.intValue,
        let second = request["max_completion_tokens"]?.intValue, first != second
      {
        throw ServiceGatewayRequestError.unsupported("Kiro 的输出上限参数不一致。")
      }
    }
    let hasManagedFields = managed.contains { request[$0] != nil }
    var normalized = false
    var warnings: [String] = []
    if textOnly && request["store"]?.boolValue == false {
      request.removeValue(forKey: "store")
      normalized = true
    }
    if textOnly && source == "chat", let options = request["stream_options"]?.objectValue,
      options.keys.allSatisfy({ $0 == "include_usage" }),
      options["include_usage"] == nil || options["include_usage"]?.boolValue != nil
    {
      if options["include_usage"]?.boolValue == true {
        warnings.append("Kiro does not provide token usage.")
      }
      request.removeValue(forKey: "stream_options")
      normalized = true
    }
    var adjusted: [String] = []
    for name in managed {
      guard let value = request.removeValue(forKey: name), supplied(value) else { continue }
      switch name {
      case "temperature", "top_p":
        try validateSampling(value, name: name, source: source)
      default:
        guard let limit = value.intValue, limit > 0 else {
          throw ServiceGatewayRequestError.unsupported("输出上限参数 \(name) 无效。")
        }
      }
      adjusted.append(name)
    }
    if textOnly { try validateKiroRequest(request, source: source) }
    guard hasManagedFields || normalized else { return (body, []) }
    if !adjusted.isEmpty {
      warnings.append("Provider manages these parameters: \(adjusted.joined(separator: ", "))")
    }
    return (try ACPJSONValue.object(request).encodedData(), warnings)
  }

  func validateSampling(_ value: ACPJSONValue, name: String, source: String) throws {
    let maximum: Double = name == "temperature" && source != "anthropic" ? 2 : 1
    guard let number = value.doubleValue, number.isFinite, (0...maximum).contains(number) else {
      throw ServiceGatewayRequestError.unsupported("采样参数 \(name) 无效。")
    }
  }

  private func validateKiroRequest(_ request: [String: ACPJSONValue], source: String) throws {
    let allowed: Set<String> =
      source == "responses"
      ? ["model", "input", "instructions", "stream"] : ["model", "messages", "stream"]
    for (name, value) in request.sorted(by: { $0.key < $1.key })
    where !allowed.contains(name) && supplied(value) {
      if name == "tools" && value.arrayValue?.isEmpty == true { continue }
      if name == "tool_choice" && value.stringValue == "auto" { continue }
      if name == "response_format" && value["type"]?.stringValue == "text" { continue }
      throw ServiceGatewayRequestError.unsupported("Kiro 的纯文本对话暂不支持参数 \(name)。")
    }
    try validateKiroMessages(
      source == "responses" ? request["input"] : request["messages"], source: source)
  }

  func validateUpstream(_ body: Data) throws {
    guard case .muse = self else { return }
    let request = try JSONDecoder().decode(ACPJSONValue.self, from: body)
    for name in [
      "generate", "prompt_cache_retention", "safety_identifier", "stream_options",
      "client_metadata",
    ] where supplied(request[name]) {
      throw ServiceGatewayRequestError.unsupported("Muse 暂不支持保留 \(name)。")
    }
    if let previous = request["previous_response_id"]?.stringValue, !previous.isEmpty {
      throw ServiceGatewayRequestError.unsupported("Muse 暂不支持引用此前的响应。")
    }
    if (request["input"]?.arrayValue ?? []).contains(where: {
      $0["type"]?.stringValue == "reasoning"
    }) {
      throw ServiceGatewayRequestError.unsupported("Muse 暂不支持保留历史推理内容。")
    }
    let tools = request["tools"]?.arrayValue ?? []
    let namespace = tools.contains {
      $0["type"]?.stringValue == "namespace" && $0["name"]?.stringValue == "muse"
    }
    if !tools.isEmpty && !namespace {
      throw ServiceGatewayRequestError.unsupported("Muse 会添加未请求的工具，当前不能处理此工具请求。")
    }
    for tool in tools {
      let nested = tool["type"]?.stringValue == "namespace" ? tool["tools"]?.arrayValue ?? [] : []
      if ([tool] + nested).contains(where: {
        $0["type"]?.stringValue == "web_search" && supplied($0["search_content_types"])
      }) {
        throw ServiceGatewayRequestError.unsupported("Muse 暂不支持指定搜索内容类型。")
      }
    }
  }

  private func validateKiroMessages(_ value: ACPJSONValue?, source: String) throws {
    if source == "responses", let text = value?.stringValue, !text.isEmpty { return }
    guard let messages = value?.arrayValue, !messages.isEmpty else {
      throw ServiceGatewayRequestError.unsupported("Kiro 暂只支持文本对话。")
    }
    var roles: [String] = []
    for message in messages {
      let type = message["type"]?.stringValue
      guard type == nil || type == "message",
        let role = message["role"]?.stringValue,
        ["system", "developer", "user", "assistant"].contains(role),
        !supplied(message["name"]),
        !supplied(message["function_call"]),
        (message["tool_calls"]?.arrayValue ?? []).isEmpty,
        isText(message["content"])
      else { throw ServiceGatewayRequestError.unsupported("Kiro 暂只支持文本对话。") }
      if role == "system" || role == "developer" {
        guard roles.isEmpty else {
          throw ServiceGatewayRequestError.unsupported("Kiro 暂不支持对话中的系统消息。")
        }
      } else {
        if role == "assistant" && roles.last == "assistant" {
          throw ServiceGatewayRequestError.unsupported("Kiro 暂不支持连续的助手消息。")
        }
        roles.append(role)
      }
    }
    guard roles.first == "user", roles.last == "user" else {
      throw ServiceGatewayRequestError.unsupported("Kiro 对话需要从用户消息开始并以用户消息结束。")
    }
  }

  private func isText(_ value: ACPJSONValue?) -> Bool {
    if let text = value?.stringValue { return !text.isEmpty }
    guard let parts = value?.arrayValue, !parts.isEmpty else { return false }
    return parts.allSatisfy {
      ["text", "input_text", "output_text"].contains($0["type"]?.stringValue ?? "")
        && $0["text"]?.stringValue != nil
    } && parts.contains { !($0["text"]?.stringValue ?? "").isEmpty }
  }

  private func supplied(_ value: ACPJSONValue?) -> Bool {
    guard let value else { return false }
    if case .null = value { return false }
    return true
  }
}

extension ServiceCommunityProviders {
  func requestCompatibility(for model: ServiceGatewayModel) async throws
    -> ServiceCommunityRequestCompatibility
  {
    guard let pluginID = model.pluginID,
      let plugin = try await records().first(where: { $0.id == pluginID && $0.isInstalled })
    else { throw ServiceCommunityProviderError.modelUnavailable }
    switch (plugin.package, plugin.version) {
    case ("@magpie-community/opencode-qoder-auth", "0.2.71"): return .qoder
    case ("@magpie-community/opencode-cursor-auth", "0.2.48"): return .cursor
    case ("@magpie-community/opencode-devin-auth", "0.1.45"): return .devin
    case ("@magpie-community/opencode-trae-auth", "0.2.43"): return .trae
    case ("@magpie-community/opencode-commandcode-auth", "0.1.24"): return .commandCode
    case ("magpie-providers-hub", "0.13.2") where model.providerID == "hub-loomy": return .loomy
    case ("magpie-providers-hub", "0.13.2") where model.providerID == "hub-accio": return .accio
    case ("magpie-providers-hub", "0.13.2")
    where ["hub-monkeycode", "hub-monkeycode-intl"].contains(model.providerID): return .monkeycode
    case ("magpie-providers-hub", "0.13.2")
    where ["hub-autoclaw", "hub-autoclaw-cn"].contains(model.providerID): return .autoclaw
    case ("@magpie-community/opencode-kiro-auth", "0.1.40"): return .kiro
    case ("magpie-muse-auth", "0.1.13"): return .muse
    default: return .standard
    }
  }
}
