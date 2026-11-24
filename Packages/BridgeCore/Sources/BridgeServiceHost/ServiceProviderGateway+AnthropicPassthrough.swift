import BridgeACP
import BridgeModelGateway
import BridgeProviderRuntime
import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

extension ServiceProviderGateway {
  static func isOfficialAnthropicPassthroughModel(
    _ id: String, gatewayModels: [ServiceGatewayModel]
  ) -> Bool {
    guard !id.isEmpty, id.utf8.count <= 128, !id.hasPrefix("community."),
      !gatewayModels.contains(where: { $0.id == id }),
      id.lowercased().hasPrefix("claude-")
    else { return false }
    return id.utf8.allSatisfy { byte in
      (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
        || [45, 46, 58, 95].contains(byte)
    }
  }

  func setAnthropicPassthroughBaseURLForTesting(_ url: URL) {
    anthropicPassthroughBaseURL = url
  }

  func forwardOfficialAnthropic(
    _ request: ModelGatewayRequest, upstreamAuth: ModelGatewayUpstreamAuth, modelID: String?,
    stream: Bool, sink: ModelGatewayResponseSink
  ) async throws {
    guard request.path == "/v1/messages" || request.path == "/v1/messages/count_tokens",
      let upstreamURL = buildAnthropicPassthroughURL(path: request.path, query: request.query)
    else {
      try await reject(sink, status: 400, code: "invalid_request")
      return
    }
    let limits = deadlines
    let timeout = Duration.seconds(limits.requestSeconds)
    let started = Date()
    let requestID = UUID().uuidString
    let trackedModel = modelID.map {
      ServiceGatewayModel(
        id: $0, name: $0, providerID: "anthropic-official", modelID: $0,
        pluginID: nil, protocolName: "anthropic", account: nil)
    }
    if let trackedModel {
      activeRequests[requestID] = .object([
        "id": .string(requestID), "clientID": .string(request.client.clientID),
        "model": .string(trackedModel.id), "state": .string("running"),
      ])
    }
    let urlRequest = buildAnthropicPassthroughRequest(
      url: upstreamURL, request: request, upstreamAuth: upstreamAuth,
      timeoutSeconds: TimeInterval(limits.requestSeconds))
    do {
      let succeeded = try await withThrowingTaskGroup(of: Bool.self) { group in
        group.addTask {
          try await ModelGatewayUpstreamRelay.stream(request: urlRequest, into: sink)
        }
        group.addTask {
          try await Task.sleep(for: timeout)
          throw ProviderRuntimeError.timedOut
        }
        if stream {
          group.addTask {
            try await sink.waitForStreamSilence(.seconds(limits.streamIdleSeconds))
            throw ProviderRuntimeError.timedOut
          }
        }
        defer { group.cancelAll() }
        return try await group.next() ?? false
      }
      if let trackedModel {
        await record(
          requestID, request: request, model: trackedModel, started: started,
          state: succeeded ? "completed" : "failed", usage: .object([:]))
      }
    } catch {
      if let trackedModel {
        await record(
          requestID, request: request, model: trackedModel, started: started,
          state: error is CancellationError || Task.isCancelled ? "cancelled" : "failed",
          usage: .object([:]))
      }
      if !(await sink.hasStarted) {
        let timedOut = error as? ProviderRuntimeError == .timedOut
        try await reject(
          sink, status: timedOut ? 504 : 502,
          code: timedOut ? "gateway_timeout" : "upstream_failed",
          message: timedOut ? "官方 Claude 接口响应超时。" : "无法连接官方 Claude 接口，请检查网络或代理设置。")
        return
      }
      if !Task.isCancelled, await sink.sendsEvents {
        let timedOut = error as? ProviderRuntimeError == .timedOut
        try await sendStreamError(
          source: "anthropic", code: timedOut ? "gateway_timeout" : "upstream_failed", sink: sink)
        return
      }
      throw error
    }
  }

  private func buildAnthropicPassthroughURL(path: String, query: String?) -> URL? {
    guard
      var components = URLComponents(
        url: anthropicPassthroughBaseURL, resolvingAgainstBaseURL: false)
    else { return nil }
    components.path = path
    components.query = query == "beta=true" ? "beta=true" : nil
    return components.url
  }

  private func buildAnthropicPassthroughRequest(
    url: URL, request: ModelGatewayRequest, upstreamAuth: ModelGatewayUpstreamAuth,
    timeoutSeconds: TimeInterval
  ) -> URLRequest {
    var outgoing = URLRequest(url: url, timeoutInterval: timeoutSeconds)
    outgoing.httpMethod = "POST"
    outgoing.httpBody = request.body
    outgoing.httpShouldHandleCookies = false
    for (name, value) in request.headers {
      let lower = name.lowercased()
      if lower == "content-type" || lower == "accept" || lower == "user-agent"
        || lower.hasPrefix("anthropic-") || lower.hasPrefix("x-claude-code-")
      {
        outgoing.setValue(value, forHTTPHeaderField: lower)
      }
    }
    if let authorization = upstreamAuth.authorization, !authorization.isEmpty {
      outgoing.setValue(authorization, forHTTPHeaderField: "authorization")
    }
    if let apiKey = upstreamAuth.apiKey, !apiKey.isEmpty {
      outgoing.setValue(apiKey, forHTTPHeaderField: "x-api-key")
    }
    return outgoing
  }
}
