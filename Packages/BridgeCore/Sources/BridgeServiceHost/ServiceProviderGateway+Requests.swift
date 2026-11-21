import BridgeACP
import BridgeEmbeddedDSH
import BridgeModelGateway
import BridgeProviderRuntime
import BridgeSecurity
import BridgeServiceCore
import Foundation

extension ServiceProviderGateway {
  func handle(
    _ request: ModelGatewayRequest, sink: ModelGatewayResponseSink,
    authentication override: ServiceGatewayAuthentication? = nil
  ) async throws {
    let authentication = override ?? self.authentication
    guard let allowed = authentication.authorizedModels(request.client) else {
      try await reject(sink, status: 401, code: "invalid_client")
      return
    }
    if request.path == "/v1/models" {
      let visible = models.filter { allowed.contains($0.id) }.map { model in
        var fields: [String: ACPJSONValue] = [
          "id": .string(model.id), "object": .string("model"),
          "owned_by": .string(model.providerID), "display_name": .string(model.name),
        ]
        // Non-standard but widely read; clients that do not know these fields ignore them.
        if let context = model.contextWindow { fields["context_window"] = .integer(Int64(context)) }
        if let output = model.defaultMaxTokens {
          fields["max_output_tokens"] = .integer(Int64(output))
        }
        return ACPJSONValue.object(fields)
      }
      try await sink.sendHead(status: 200, headers: ["content-type": "application/json"])
      try await sink.send(
        ACPJSONValue.object([
          "object": .string("list"), "data": .array(visible), "has_more": .bool(false),
          "first_id": visible.first?["id"] ?? .null, "last_id": visible.last?["id"] ?? .null,
        ]).encodedData())
      return
    }
    if request.path == "/v1/messages/count_tokens" {
      guard authentication.allowsAnthropicPassthrough(request.client),
        let upstreamAuth = request.upstreamAuth, upstreamAuth.hasCredential
      else {
        try await reject(sink, status: 404, code: "not_found")
        return
      }
      if let body = try? JSONDecoder().decode(ACPJSONValue.self, from: request.body).objectValue,
        let id = body["model"]?.stringValue,
        !Self.isOfficialAnthropicPassthroughModel(id, gatewayModels: models)
      {
        try await reject(sink, status: 404, code: "not_found")
        return
      }
      try await forwardOfficialAnthropic(
        request, upstreamAuth: upstreamAuth, modelID: nil, stream: false, sink: sink)
      return
    }
    guard var body = try? JSONDecoder().decode(ACPJSONValue.self, from: request.body).objectValue,
      let id = body["model"]?.stringValue
    else {
      try await reject(sink, status: 400, code: "invalid_request")
      return
    }
    guard allowed.contains(id), let model = models.first(where: { $0.id == id }) else {
      if request.path == "/v1/messages",
        authentication.allowsAnthropicPassthrough(request.client),
        Self.isOfficialAnthropicPassthroughModel(id, gatewayModels: models)
      {
        guard let upstreamAuth = request.upstreamAuth, upstreamAuth.hasCredential else {
          try await reject(
            sink, status: 401, code: "official_auth_missing",
            message: "未收到 Claude 官方登录凭据，请先在 Claude Code 中登录官方账号。")
          return
        }
        try await forwardOfficialAnthropic(
          request, upstreamAuth: upstreamAuth, modelID: id,
          stream: body["stream"]?.boolValue == true, sink: sink)
        return
      }
      try await reject(sink, status: 403, code: "model_not_authorized")
      return
    }
    body["model"] = .string(model.modelID)
    let input = try ACPJSONValue.object(body).encodedData()
    let streamsResponse = body["stream"]?.boolValue == true
    let started = Date()
    let requestID = UUID().uuidString
    let source: String
    switch request.path {
    case "/v1/responses": source = "responses"
    case "/v1/messages": source = "anthropic"
    default: source = "chat"
    }
    // Protocol conversion always asks the upstream to stream, including for a JSON client.
    let usage = ServiceGatewayUsage(stream: streamsResponse || source != model.protocolName)
    activeRequests[requestID] = .object([
      "id": .string(requestID), "clientID": .string(request.client.clientID),
      "model": .string(model.id), "state": .string("queued"),
    ])
    do {
      let limits = deadlines
      let timeout = Duration.seconds(limits.requestSeconds)
      let completed = try await withThrowingTaskGroup(of: Bool.self) { group in
        group.addTask { [self] in
          try await scheduler.withPermit(
            account: model.account ?? model.providerID, accountLimit: model.maximumConcurrency ?? 2
          ) { [self] in
            guard authentication.authorizedModels(request.client)?.contains(model.id) == true else {
              throw ServiceGatewayRequestError.unauthorized
            }
            await self.markRunning(requestID)
            return try await self.forward(
              model: model, body: input, source: source, headers: request.headers,
              stream: streamsResponse, sink: sink, usage: usage, timeout: timeout)
          }
        }
        group.addTask {
          try await Task.sleep(for: timeout)
          throw ProviderRuntimeError.timedOut
        }
        if streamsResponse {
          group.addTask {
            try await sink.waitForStreamSilence(.seconds(limits.streamIdleSeconds))
            throw ProviderRuntimeError.timedOut
          }
        }
        defer { group.cancelAll() }
        return try await group.next() ?? false
      }
      let tokens = await usage.presentation()
      let upstreamFailed = await usage.upstreamFailed
      await record(
        requestID, request: request, model: model, started: started,
        state: completed && !upstreamFailed ? "completed" : "failed", usage: tokens)
    } catch {
      await record(
        requestID, request: request, model: model, started: started,
        state: error is CancellationError || Task.isCancelled ? "cancelled" : "failed",
        usage: await usage.presentation())
      if !(await sink.hasStarted) {
        if case ServiceGatewayRequestError.unauthorized = error {
          try await reject(sink, status: 401, code: "invalid_client")
          return
        }
        if case ServiceGatewayRequestError.unsupported(let message) = error {
          try await reject(
            sink, status: 400, code: "unsupported_request",
            message: OutboundContentSecurity.redactedSecrets(message, maximumUTF8Bytes: 2048))
          return
        }
        if error as? ProviderRuntimeError == .timedOut {
          try await reject(sink, status: 504, code: "gateway_timeout")
          return
        }
        let status = error is ModelGatewayAdmissionError ? 429 : 502
        try await reject(
          sink, status: status, code: status == 429 ? "rate_limit_exceeded" : "upstream_failed")
        return
      }
      if !Task.isCancelled, await sink.sendsEvents {
        let timeout = error as? ProviderRuntimeError == .timedOut
        try await sendStreamError(
          source: source, code: timeout ? "gateway_timeout" : "upstream_failed", sink: sink)
        return
      }
      throw error
    }
  }

  func sendStreamError(source: String, code: String, sink: ModelGatewayResponseSink) async throws {
    let message = code == "gateway_timeout" ? "模型请求已超时。" : "供应商未能完成响应。"
    let detail: ACPJSONValue = .object([
      "type": .string("api_error"), "code": .string(code), "message": .string(message),
    ])
    let payload: ACPJSONValue
    switch source {
    case "responses":
      payload = .object([
        "type": .string("error"), "code": .string(code), "message": .string(message),
      ])
    case "anthropic":
      payload = .object(["type": .string("error"), "error": detail])
    default:
      payload = .object(["error": detail])
    }
    let prefix = source == "chat" ? "" : "event: error\n"
    let json = String(decoding: try payload.encodedData(), as: UTF8.self)
    try await sink.send(Data("\(prefix)data: \(json)\n\n".utf8))
  }

  private func forward(
    model: ServiceGatewayModel, body: Data, source: String, headers: [String: String], stream: Bool,
    sink: ModelGatewayResponseSink, usage: ServiceGatewayUsage, timeout: Duration
  ) async throws -> Bool {
    let compatibility: ServiceCommunityRequestCompatibility?
    if model.pluginID != nil, let communityProviders {
      compatibility = try await communityProviders.requestCompatibility(for: model)
    } else {
      compatibility = nil
    }
    let adapted =
      try compatibility?.adaptOriginal(
        body, source: source, supportsSampling: model.supportsSampling) ?? (
        body: body, warnings: [String]()
      )
    let conversion: ServiceModelConversion?
    let upstreamBody: Data
    if source == model.protocolName {
      conversion = nil
      upstreamBody = adapted.body
    } else {
      let converter = try await ServiceModelConversion(
        resources: try await resources(),
        directory: dataRoot.appendingPathComponent("ProtocolState"))
      do {
        upstreamBody = try await converter.translate(
          body: adapted.body, from: source, to: model.protocolName, model: model.modelID,
          host: "", plugin: model.pluginID != nil)
        conversion = converter
      } catch {
        try await converter.close()
        throw error
      }
    }
    do {
      let upstream =
        try compatibility?.adaptUpstream(
          upstreamBody, protocolName: model.protocolName, supportsImages: model.supportsImages)
        ?? (body: upstreamBody, warnings: [String]())
      let response = ServiceGatewayOutput(
        sink: sink, conversion: conversion, stream: stream,
        compatibilityWarnings: adapted.warnings + upstream.warnings)
      let completed: Bool
      if model.pluginID == nil {
        completed = try await forwardExisting(
          model: model, body: upstreamBody, response: response, sink: sink,
          usage: usage, timeout: timeout)
      } else {
        let anthropicHeaders =
          source == "anthropic" && model.protocolName == source
          ? headers.filter { ["anthropic-beta", "anthropic-version"].contains($0.key) } : [:]
        completed = try await forwardCommunity(
          model: model, body: upstream.body, headers: anthropicHeaders, response: response,
          usage: usage, timeout: timeout)
      }
      if completed { try await response.finish() }
      try await conversion?.close()
      return completed
    } catch {
      if let conversion { try await conversion.close() }
      throw error
    }
  }

  private func forwardExisting(
    model: ServiceGatewayModel, body: Data, response: ServiceGatewayOutput,
    sink: ModelGatewayResponseSink, usage: ServiceGatewayUsage,
    timeout: Duration
  ) async throws -> Bool {
    let id = UUID().uuidString
    let payload = ACPJSONValue.object([
      "id": .string(id), "provider": .string(model.providerID), "model": .string(model.modelID),
      "request": try JSONDecoder().decode(ACPJSONValue.self, from: body),
    ])
    do {
      let opened: ACPJSONValue
      do {
        opened = try await existing.call("gateway.stream.open", payload: payload, timeout: timeout)
      } catch EmbeddedDSHRuntimeError.remote(_, let message) {
        throw ServiceGatewayRequestError.unsupported(message)
      }
      if let failure = opened["failure"] {
        try await Self.upstreamFailure(failure, sink: sink)
        return false
      }
      let warnings = opened["warnings"]?.arrayValue?.compactMap(\.stringValue) ?? []
      var headers = ["cache-control": "no-cache"]
      if !warnings.isEmpty {
        headers["warning"] = warnings.map { "299 CodexBridge \"\($0)\"" }.joined(separator: ", ")
      }
      await response.prepare(status: 200, headers: headers)
      while true {
        try Task.checkCancellation()
        let result = try await existing.call(
          "gateway.stream.next", payload: .object(["id": .string(id)]), timeout: timeout)
        if let reported = result["usage"] { await usage.receiveReported(reported) }
        if let failure = result["failure"] {
          guard !(await sink.hasStarted) else {
            throw ProviderRuntimeError.remote("upstream_failed")
          }
          try await Self.upstreamFailure(failure, sink: sink)
          return false
        }
        if let chunk = result["chunk"]?.stringValue, !chunk.isEmpty {
          try await response.receive(Data(chunk.utf8))
        }
        if result["done"]?.boolValue == true { return true }
      }
    } catch {
      let owner = existing
      _ = try await Task.detached {
        try await owner.cancelGatewayStream(id)
      }.value
      throw error
    }
  }

  static func upstreamFailure(_ failure: ACPJSONValue, sink: ModelGatewayResponseSink) async throws
  {
    let code = failure["code"]?.stringValue ?? "upstream_failed"
    let mappedStatus: Int
    let summary: String
    switch code {
    case "SIWC_UNSUPPORTED_PARAMETER":
      mappedStatus = 400
      summary = "ChatGPT SIWC 不支持这次请求中的参数。"
    case "QUOTA_EXHAUSTED":
      mappedStatus = 402
      summary = "供应商额度已用尽，请查看套餐用量或选择其他模型。"
    case "UNSUPPORTED_REASONING_EFFORT":
      mappedStatus = 400
      summary = "所选模型不支持此次请求的推理强度，请调整推理选项或选择其他模型。"
    case "INVALID_REQUEST", "CONTEXT_WINDOW_EXCEEDED", "UNSUPPORTED_CONTENT", "UNSUPPORTED_OPTION":
      mappedStatus = 400
      summary = "模型无法处理这次请求的内容或参数。"
    case "AUTH", "ACCOUNT_SIGN_IN_REQUIRED", "ACCOUNT_TOKEN_INVALID", "MISSING_CREDENTIAL",
      "INVALID_CREDENTIAL":
      mappedStatus = 401
      summary = "供应商认证失败，请在 Bridge 供应商页检查连接。"
    case "QUOTA", "ACCOUNT_QUOTA":
      mappedStatus = 402
      summary = "供应商报告额度不足。"
    case "RATE_LIMIT":
      mappedStatus = 429
      summary = "供应商已限制请求频率。"
    case "NOT_FOUND", "UNKNOWN_MODEL", "MODEL_UNSUPPORTED":
      mappedStatus = 404
      summary = "供应商无法提供所选模型。"
    default:
      mappedStatus = 502
      summary = "供应商未能完成请求。"
    }
    // Some suppliers use HTTP 429 for both temporary throttling and exhausted plan quota.
    let terminal = code == "QUOTA_EXHAUSTED" || code == "SIWC_UNSUPPORTED_PARAMETER"
    let status = terminal ? mappedStatus : failure["status"]?.intValue ?? mappedStatus
    let message: String
    if ["UNSUPPORTED_CONTENT", "UNSUPPORTED_OPTION", "SIWC_UNSUPPORTED_PARAMETER"].contains(code),
      let explanation = failure["message"]?.stringValue
    {
      message = OutboundContentSecurity.redactedSecrets(explanation, maximumUTF8Bytes: 2048)
    } else {
      message = "\(summary)（\(code)）"
    }
    var headers = ["content-type": "application/json"]
    if !terminal, let retry = failure["retryAfter"]?.intValue, retry > 0 {
      headers["retry-after"] = String((retry + 999) / 1000)
    }
    try await sink.sendHead(status: (400...599).contains(status) ? status : 502, headers: headers)
    try await sink.send(
      ACPJSONValue.object([
        "error": .object([
          "code": failure["code"] ?? .string("upstream_failed"),
          "message": .string(message),
        ])
      ]).encodedData())
  }

  func reject(
    _ sink: ModelGatewayResponseSink, status: Int, code: String, message: String? = nil
  ) async throws {
    try await sink.sendHead(status: status, headers: ["content-type": "application/json"])
    try await sink.send(
      ACPJSONValue.object([
        "error": .object(["code": .string(code), "message": .string(message ?? code)])
      ]).encodedData())
  }

}
