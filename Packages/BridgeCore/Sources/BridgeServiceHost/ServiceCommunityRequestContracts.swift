import BridgeACP
import Foundation

extension ServiceCommunityRequestCompatibility {
  func adaptUpstream(_ body: Data, protocolName: String, supportsImages: Bool? = nil) throws -> (
    body: Data, warnings: [String]
  ) {
    try validateUpstream(body)
    switch self {
    case .standard, .kiro, .muse:
      return (body, [])
    default:
      break
    }
    guard var request = try JSONDecoder().decode(ACPJSONValue.self, from: body).objectValue else {
      throw ServiceGatewayRequestError.unsupported("模型请求格式无效。")
    }
    if self == .devin && protocolName == "anthropic" {
      try adaptImages(&request, protocolName: protocolName, supportsImages: supportsImages)
      try adaptDevinMessages(&request)
      return (try ACPJSONValue.object(request).encodedData(), [])
    }
    guard protocolName == "chat" else {
      throw ServiceGatewayRequestError.unsupported("该插件暂不支持此模型协议。")
    }
    if self == .autoclaw {
      let limits = try removeManagedParameters(["max_tokens"], from: &request)
      return (try ACPJSONValue.object(request).encodedData(), managedWarning(limits))
    }
    try adaptImages(&request, protocolName: protocolName, supportsImages: supportsImages)
    if self == .devin, request["model"]?.stringValue?.lowercased().contains("claude") == true {
      for message in request["messages"]?.arrayValue ?? [] {
        if suppliedContract(message["reasoning_content"]) || suppliedContract(message["reasoning"])
        {
          throw ServiceGatewayRequestError.unsupported("Devin 无法保留 Claude 的推理历史。")
        }
      }
    }
    try validateChatContract(&request)
    let sampling: [String]
    switch self {
    case .qoder, .cursor: sampling = ["temperature", "top_p"]
    case .trae, .commandCode, .loomy, .accio, .monkeycode: sampling = ["top_p"]
    default: sampling = []
    }
    var managed = try removeManagedParameters(sampling, from: &request)
    if self == .cursor {
      managed += try removeManagedParameters(
        ["max_tokens", "max_completion_tokens"], from: &request)
    }
    if [.loomy, .accio, .monkeycode].contains(self) {
      try translateOutputLimit(&request)
    }
    var warnings = managedWarning(managed)
    if [.qoder, .trae, .commandCode, .monkeycode].contains(self) {
      let limits = ["max_tokens", "max_completion_tokens"].filter { suppliedContract(request[$0]) }
      if !limits.isEmpty {
        warnings.append("Provider may limit these parameters: \(limits.joined(separator: ", "))")
      }
    }
    return (try ACPJSONValue.object(request).encodedData(), warnings)
  }

  private func validateChatContract(_ request: inout [String: ACPJSONValue]) throws {
    if let count = request["n"], suppliedContract(count), count.intValue != 1 {
      throw ServiceGatewayRequestError.unsupported("该插件不支持一次生成多个回复。")
    }
    if suppliedContract(request["functions"]), request["functions"]?.arrayValue?.isEmpty != true {
      throw ServiceGatewayRequestError.unsupported("该插件需要使用 tools 和 tool_choice 定义工具。")
    }
    if let choice = request["function_call"], suppliedContract(choice),
      !["auto", "none"].contains(choice.stringValue ?? "")
    {
      throw ServiceGatewayRequestError.unsupported("该插件需要使用 tools 和 tool_choice 定义工具。")
    }
    for name in ["max_tokens", "max_completion_tokens"] {
      if let value = request[name], suppliedContract(value) {
        guard let limit = value.intValue, limit > 0 else {
          throw ServiceGatewayRequestError.unsupported("输出上限参数 \(name) 无效。")
        }
      }
    }
    if let format = request["response_format"], suppliedContract(format),
      format["type"]?.stringValue != "text"
    {
      throw ServiceGatewayRequestError.unsupported("该插件不能保证请求的结构化输出格式。")
    }
    if [.loomy, .accio, .monkeycode].contains(self) {
      try normalizeStop(&request)
    } else if let stop = request["stop"], suppliedContract(stop), stop.arrayValue?.isEmpty != true {
      throw ServiceGatewayRequestError.unsupported("该插件不支持请求的停止条件。")
    }
    let choice = request["tool_choice"]
    if choice?.stringValue == "none" {
      request.removeValue(forKey: "tools")
      request.removeValue(forKey: "tool_choice")
    } else if self != .trae, suppliedContract(choice), choice?.stringValue != "auto" {
      throw ServiceGatewayRequestError.unsupported("该插件不能保证强制或指定的工具调用。")
    }
    let tools = try chatTools(request["tools"])
    if self == .trae && tools.isEmpty && hasToolHistory(request["messages"]) {
      throw ServiceGatewayRequestError.unsupported("Trae 需要工具定义才能保留此前的工具调用和结果。")
    }
    if suppliedContract(request["parallel_tool_calls"]),
      request["parallel_tool_calls"]?.boolValue == nil
    {
      throw ServiceGatewayRequestError.unsupported("parallel_tool_calls 格式无效。")
    }
    if self != .trae, !tools.isEmpty, request["parallel_tool_calls"]?.boolValue == false {
      throw ServiceGatewayRequestError.unsupported("该插件不能保证禁止并行工具调用。")
    }
    if self != .loomy {
      try validateStrictTools(tools, anthropic: false)
    }
  }

  private func adaptDevinMessages(_ request: inout [String: ACPJSONValue]) throws {
    for message in request["messages"]?.arrayValue ?? [] {
      for block in message["content"]?.arrayValue ?? []
      where block["type"]?.stringValue == "thinking" {
        if !(block["signature"]?.stringValue ?? "").isEmpty {
          throw ServiceGatewayRequestError.unsupported("Devin 不能保证保留有签名的推理历史。")
        }
      }
    }
    if let stop = request["stop_sequences"], suppliedContract(stop),
      stop.arrayValue?.isEmpty != true
    {
      throw ServiceGatewayRequestError.unsupported("Devin 不支持请求的停止条件。")
    }
    if suppliedContract(request["output_config"]?["format"]) {
      throw ServiceGatewayRequestError.unsupported("Devin 不能保证请求的结构化输出格式。")
    }
    let choice = request["tool_choice"]
    let choiceType = choice?["type"]?.stringValue
    if choiceType == "none" {
      request.removeValue(forKey: "tools")
      request.removeValue(forKey: "tool_choice")
    } else if suppliedContract(choice), choiceType != "auto" {
      throw ServiceGatewayRequestError.unsupported("Devin 不能保证强制或指定的工具调用。")
    }
    let tools = try anthropicTools(request["tools"])
    if !tools.isEmpty && choice?["disable_parallel_tool_use"]?.boolValue == true {
      throw ServiceGatewayRequestError.unsupported("Devin 不能保证禁止并行工具调用。")
    }
    try validateStrictTools(tools, anthropic: true)
  }

  private func chatTools(_ value: ACPJSONValue?) throws -> [ACPJSONValue] {
    guard suppliedContract(value) else { return [] }
    guard let tools = value?.arrayValue else {
      throw ServiceGatewayRequestError.unsupported("工具定义格式无效。")
    }
    guard
      tools.allSatisfy({
        $0["type"]?.stringValue == "function"
          && !($0["function"]?["name"]?.stringValue ?? "").isEmpty
      })
    else { throw ServiceGatewayRequestError.unsupported("该插件只支持函数工具。") }
    return tools
  }

  private func anthropicTools(_ value: ACPJSONValue?) throws -> [ACPJSONValue] {
    guard suppliedContract(value) else { return [] }
    guard let tools = value?.arrayValue else {
      throw ServiceGatewayRequestError.unsupported("工具定义格式无效。")
    }
    guard
      tools.allSatisfy({
        ($0["type"] == nil || $0["type"]?.stringValue == "custom")
          && !($0["name"]?.stringValue ?? "").isEmpty
      })
    else { throw ServiceGatewayRequestError.unsupported("Devin 只支持自定义函数工具。") }
    return tools
  }

  private func validateStrictTools(_ tools: [ACPJSONValue], anthropic: Bool) throws {
    for tool in tools {
      let strict = anthropic ? tool["strict"] : tool["function"]?["strict"]
      guard suppliedContract(strict) else { continue }
      guard let value = strict?.boolValue, !value else {
        throw ServiceGatewayRequestError.unsupported("该插件不能保证严格的工具参数格式。")
      }
    }
  }

  private func hasToolHistory(_ value: ACPJSONValue?) -> Bool {
    (value?.arrayValue ?? []).contains {
      $0["role"]?.stringValue == "tool" || !($0["tool_calls"]?.arrayValue ?? []).isEmpty
    }
  }

  private func normalizeStop(_ request: inout [String: ACPJSONValue]) throws {
    guard let stop = request["stop"], suppliedContract(stop) else { return }
    if let string = stop.stringValue, !string.isEmpty {
      if self == .loomy { request["stop"] = .array([.string(string)]) }
      return
    }
    guard let values = stop.arrayValue,
      values.allSatisfy({ !($0.stringValue ?? "").isEmpty })
    else { throw ServiceGatewayRequestError.unsupported("停止条件格式无效。") }
  }

  private func translateOutputLimit(_ request: inout [String: ACPJSONValue]) throws {
    guard let completion = request["max_completion_tokens"], suppliedContract(completion) else {
      return
    }
    guard let limit = completion.intValue, limit > 0 else {
      throw ServiceGatewayRequestError.unsupported("输出上限参数 max_completion_tokens 无效。")
    }
    if let existing = request["max_tokens"], suppliedContract(existing), existing.intValue != limit
    {
      throw ServiceGatewayRequestError.unsupported("输出上限参数不一致。")
    }
    request["max_tokens"] = completion
    request.removeValue(forKey: "max_completion_tokens")
  }

  private func removeManagedParameters(
    _ names: [String], from request: inout [String: ACPJSONValue]
  ) throws -> [String] {
    var removed: [String] = []
    for name in names {
      guard let value = request.removeValue(forKey: name), suppliedContract(value) else { continue }
      if name == "temperature" || name == "top_p" {
        try validateSampling(value, name: name, source: "chat")
      } else {
        guard let limit = value.intValue, limit > 0 else {
          throw ServiceGatewayRequestError.unsupported("输出上限参数 \(name) 无效。")
        }
      }
      removed.append(name)
    }
    return removed
  }

  private func managedWarning(_ names: [String]) -> [String] {
    names.isEmpty ? [] : ["Provider manages these parameters: \(names.joined(separator: ", "))"]
  }

  private func adaptImages(
    _ request: inout [String: ACPJSONValue], protocolName: String, supportsImages: Bool?
  ) throws {
    guard [.cursor, .devin, .trae, .accio].contains(self),
      var messages = request["messages"]?.arrayValue
    else { return }
    for index in messages.indices {
      guard var message = messages[index].objectValue, let content = message["content"] else {
        continue
      }
      message["content"] = try adaptImageContent(
        content, protocolName: protocolName, supportsImages: supportsImages)
      messages[index] = .object(message)
    }
    request["messages"] = .array(messages)
  }

  private func adaptImageContent(
    _ content: ACPJSONValue, protocolName: String, supportsImages: Bool?
  ) throws -> ACPJSONValue {
    guard var parts = content.arrayValue else { return content }
    for index in parts.indices {
      guard var part = parts[index].objectValue else { continue }
      let type = part["type"]?.stringValue
      if type == "image" && protocolName == "anthropic" {
        guard part["source"]?["type"]?.stringValue == "base64",
          !(part["source"]?["data"]?.stringValue ?? "").isEmpty
        else { throw ServiceGatewayRequestError.unsupported("Devin 只支持内嵌图片，不支持远程图片地址。") }
      } else if type == "image_url" || type == "input_image" {
        let url =
          part["image_url"]?.stringValue ?? part["image_url"]?["url"]?.stringValue
          ?? part["url"]?.stringValue ?? ""
        guard !url.isEmpty else {
          throw ServiceGatewayRequestError.unsupported("图片地址无效。")
        }
        if self == .trae && supportsImages != true {
          throw ServiceGatewayRequestError.unsupported("所选 Trae 模型未声明支持图片。")
        }
        if self == .cursor || self == .devin || self == .accio {
          guard type == "image_url", isInlineImage(url) else {
            throw ServiceGatewayRequestError.unsupported("该插件只支持内嵌图片，不支持远程图片地址。")
          }
          if self == .accio, part["image_url"]?.stringValue != nil {
            part["image_url"] = .object(["url": .string(url)])
          }
        }
      }
      if let nested = part["content"] {
        part["content"] = try adaptImageContent(
          nested, protocolName: protocolName, supportsImages: supportsImages)
      }
      parts[index] = .object(part)
    }
    return .array(parts)
  }

  private func isInlineImage(_ url: String) -> Bool {
    guard url.hasPrefix("data:"), let marker = url.range(of: ";base64,") else { return false }
    return marker.lowerBound > url.index(url.startIndex, offsetBy: 5)
      && marker.upperBound < url.endIndex
  }

  private func suppliedContract(_ value: ACPJSONValue?) -> Bool {
    guard let value else { return false }
    if case .null = value { return false }
    return true
  }
}
