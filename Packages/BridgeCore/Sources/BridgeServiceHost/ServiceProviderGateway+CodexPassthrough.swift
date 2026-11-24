import BridgeACP
import BridgeModelGateway
import BridgeProviderRuntime
import Crypto
import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

extension ServiceProviderGateway {
  func codexGatewayModels(_ allowed: [String]) -> [ServiceGatewayModel] {
    let authorized = Set(allowed)
    return models.filter { authorized.contains($0.id) && $0.codexCoexistenceEligible }
  }

  func codexTakeoverCatalog(_ allowed: [String]) throws -> Data {
    let authorized = Set(allowed)
    return try ServiceCodexGatewayCatalog.takeover(
      gatewayModels: models.filter { authorized.contains($0.id) })
  }

  func setCodexUpstreamEndpointsForTesting(_ endpoints: CodexUpstreamEndpoints) {
    codexUpstreamEndpoints = endpoints
    codexOfficialModels = CodexOfficialModelCache()
  }

  func serveCodexCatalog(
    _ request: ModelGatewayRequest, authentication: ServiceGatewayAuthentication,
    sink: ModelGatewayResponseSink
  ) async throws {
    guard let query = request.query else {
      try await reject(sink, status: 400, code: "codex_client_version_required")
      return
    }
    try await handleCodexUpstreamErrors(sink) {
      let localPromptCatalog = try await self.externalApplications?.codexPromptCatalog(
        clientID: request.client.clientID)
      let response = try await self.fetchCodexCatalog(request, query: query)
      guard authentication.allowsCodexPassthrough(request.client),
        let allowed = authentication.authorizedModels(request.client)
      else { throw ServiceGatewayRequestError.unauthorized }
      guard response.status == 200 else {
        try await self.sendCodexCatalogError(response, sink: sink)
        return
      }
      let merged = try ServiceCodexGatewayCatalog.merge(
        official: response.body, gatewayModels: self.codexGatewayModels(allowed),
        localPromptCatalog: localPromptCatalog)
      try self.rememberOfficialModels(response, request: request, query: query)
      try await sink.sendHead(
        status: 200, headers: ["content-type": "application/json", "cache-control": "no-store"])
      try await Self.sendCodexData(merged, sink: sink)
    }
  }

  func forwardOfficialCodex(
    _ request: ModelGatewayRequest, modelID: String, body: [String: ACPJSONValue],
    authentication: ServiceGatewayAuthentication, sink: ModelGatewayResponseSink
  ) async throws {
    guard let query = Self.codexVersionQuery(userAgent: request.headers["user-agent"]) else {
      try await reject(sink, status: 400, code: "codex_client_version_required")
      return
    }
    var replay = body
    Self.projectCodexHistory(&replay, official: true)
    let data = replay == body ? request.body : try ACPJSONValue.object(replay).encodedData()
    let limits = deadlines
    try await handleCodexUpstreamErrors(sink) {
      try await self.scheduler.withPermit(account: "codex-official:" + request.client.clientID) {
        guard authentication.allowsCodexPassthrough(request.client) else {
          throw ServiceGatewayRequestError.unauthorized
        }
        guard
          try await self.authorizeOfficialCodexModel(
            modelID, request: request, query: query, authentication: authentication, sink: sink)
        else { return }
        var prepared = await self.codexUpstreamRequest(
          request, target: self.codexUpstreamEndpoints.responses, body: data,
          timeout: TimeInterval(limits.requestSeconds))
        if prepared.value(forHTTPHeaderField: "x-codex-routing-hint") == nil {
          prepared.setValue(
            Self.codexRoutingHint(body: body, headers: request.headers),
            forHTTPHeaderField: "x-codex-routing-hint")
        }
        let outgoing = prepared
        let streams = body["stream"]?.boolValue == true
        let usage = ServiceGatewayUsage(stream: streams)
        let started = Date()
        let relay: @Sendable () async throws -> Bool = {
          try await ModelGatewayUpstreamRelay.stream(
            request: outgoing, into: sink, allowedHeaders: Self.codexResponseHeaders,
            observe: { await usage.receive($0) })
        }
        do {
          let succeeded: Bool
          if streams {
            succeeded = try await withThrowingTaskGroup(of: Bool.self) { tasks in
              tasks.addTask { try await relay() }
              tasks.addTask {
                try await sink.waitForStreamSilence(.seconds(limits.streamIdleSeconds))
                throw ProviderRuntimeError.timedOut
              }
              defer { tasks.cancelAll() }
              return try await tasks.next() ?? false
            }
          } else {
            succeeded = try await relay()
          }
          let failed = await usage.upstreamFailed
          await self.recordOfficialCodex(
            request: request, model: modelID, started: started,
            state: succeeded && !failed ? "completed" : "failed", usage: await usage.presentation())
        } catch {
          await self.recordOfficialCodex(
            request: request, model: modelID, started: started,
            state: error is CancellationError || Task.isCancelled ? "cancelled" : "failed",
            usage: await usage.presentation())
          throw error
        }
      }
    }
  }

  private func authorizeOfficialCodexModel(
    _ modelID: String, request: ModelGatewayRequest, query: String,
    authentication: ServiceGatewayAuthentication, sink: ModelGatewayResponseSink
  ) async throws -> Bool {
    switch try await officialCodexModelIDs(request, query: query, authentication: authentication) {
    case .failed(let response):
      try await sendCodexCatalogError(response, sink: sink)
      return false
    case .ids(let officialIDs):
      guard officialIDs.contains(modelID) else {
        try await reject(sink, status: 403, code: "model_not_authorized")
        return false
      }
      return true
    }
  }

  enum OfficialCodexModels {
    case ids(Set<String>)
    case failed(ModelGatewayUpstreamRelay.Reply)
  }

  func officialCodexModelIDs(
    _ request: ModelGatewayRequest, query: String, authentication: ServiceGatewayAuthentication
  ) async throws -> OfficialCodexModels {
    if let cached = codexOfficialModels.ids(for: .init(request: request, query: query)) {
      return .ids(cached)
    }
    let response = try await fetchCodexCatalog(request, query: query)
    guard authentication.allowsCodexPassthrough(request.client) else {
      throw ServiceGatewayRequestError.unauthorized
    }
    guard response.status == 200 else { return .failed(response) }
    return .ids(try rememberOfficialModels(response, request: request, query: query))
  }

  private func fetchCodexCatalog(
    _ request: ModelGatewayRequest, query: String
  ) async throws -> ModelGatewayUpstreamRelay.Reply {
    let version = String(query.dropFirst("client_version=".count))
    let target = codexUpstreamEndpoints.models.appending(queryItems: [
      URLQueryItem(name: "client_version", value: version)
    ])
    let outgoing = codexUpstreamRequest(
      request, target: target, timeout: TimeInterval(min(15, deadlines.requestSeconds)))
    return try await ModelGatewayUpstreamRelay.read(
      request: outgoing, maximumBytes: 8 * 1024 * 1024)
  }

  @discardableResult
  private func rememberOfficialModels(
    _ response: ModelGatewayUpstreamRelay.Reply, request: ModelGatewayRequest, query: String
  ) throws -> Set<String> {
    let ids = try ServiceCodexGatewayCatalog.officialModelIDs(in: response.body)
    codexOfficialModels.store(
      ids, for: .init(request: request, query: query),
      cacheControl: response.headers["cache-control"])
    return ids
  }

  private func codexUpstreamRequest(
    _ request: ModelGatewayRequest, target: URL, body: Data? = nil,
    timeout: TimeInterval
  ) -> URLRequest {
    var outgoing = URLRequest(url: target, timeoutInterval: timeout)
    outgoing.httpMethod = body == nil ? "GET" : "POST"
    outgoing.httpShouldHandleCookies = false
    outgoing.httpBody = body
    outgoing.setValue(request.upstreamAuth?.authorization, forHTTPHeaderField: "Authorization")
    outgoing.setValue(
      request.upstreamAuth?.chatGPTAccountID, forHTTPHeaderField: "ChatGPT-Account-ID")
    for name in ["originator", "user-agent"] {
      outgoing.setValue(request.headers[name], forHTTPHeaderField: name)
    }
    if body != nil {
      outgoing.setValue("application/json", forHTTPHeaderField: "Content-Type")
      for name in Self.codexInferenceHeaders {
        outgoing.setValue(request.headers[name], forHTTPHeaderField: name)
      }
    } else {
      outgoing.setValue("application/json", forHTTPHeaderField: "Accept")
    }
    return outgoing
  }

  private func sendCodexCatalogError(
    _ response: ModelGatewayUpstreamRelay.Reply, sink: ModelGatewayResponseSink
  ) async throws {
    guard (400...599).contains(response.status) else {
      throw ProviderRuntimeError.remote("invalid_codex_catalog_response")
    }
    try await sink.sendHead(
      status: response.status,
      headers: response.headers.filter { Self.codexResponseHeaders.contains($0.key) })
    try await Self.sendCodexData(response.body, sink: sink)
  }

  private func handleCodexUpstreamErrors(
    _ sink: ModelGatewayResponseSink, operation: () async throws -> Void
  ) async throws {
    do {
      try await operation()
    } catch {
      try Task.checkCancellation()
      let timedOut =
        error as? ProviderRuntimeError == .timedOut
        || (error as? URLError)?.code == .timedOut
      if await sink.hasStarted {
        // An upstream interruption can arrive between SSE frames. Closing lets Codex retry
        // the missing completion event instead of appending a corrupt partial event.
        throw error
      }
      if case ServiceGatewayRequestError.unauthorized = error {
        try await reject(sink, status: 401, code: "invalid_client")
      } else if error as? ExternalAgentConnectionError == .unreadableCodexPromptCatalog
        || error as? ServiceCodexGatewayCatalogError == .invalidLocalPromptCatalog
      {
        try await reject(
          sink, status: 409, code: "codex_local_prompt_catalog_unavailable",
          message: "无法加载本地模型提示词。请检查原模型目录文件或撤销共存配置。")
      } else if error is ModelGatewayAdmissionError {
        try await reject(sink, status: 429, code: "rate_limit_exceeded")
      } else {
        try await reject(
          sink, status: timedOut ? 504 : 502,
          code: timedOut ? "gateway_timeout" : "codex_upstream_failed")
      }
    }
  }

  private static func sendCodexData(_ body: Data, sink: ModelGatewayResponseSink) async throws {
    for offset in stride(from: 0, to: body.count, by: 64 * 1024) {
      try await sink.send(body.subdata(in: offset..<min(offset + 64 * 1024, body.count)))
    }
  }

  /// Codex sends this load-balancer hint only to its built-in OpenAI provider, so the gateway
  /// rebuilds it from the same body fields. Guardian reviews omit it natively.
  static func codexRoutingHint(body: [String: ACPJSONValue], headers: [String: String]) -> String? {
    guard headers["x-codex-guardian"] == nil, headers["x-openai-subagent"] != "guardian",
      let model = body["model"]?.stringValue, !model.isEmpty
    else { return nil }
    let hint = body["service_tier"]?.stringValue.map { "model=\(model);tier=\($0)" }
    let value = hint ?? "model=\(model)"
    guard value.utf8.allSatisfy({ (0x21...0x7e).contains($0) }) else { return nil }
    return value
  }

  static func codexVersionQuery(userAgent: String?) -> String? {
    // The custom Responses endpoint uses Codex's default User-Agent, including its engine version.
    guard let agent = userAgent, let slash = agent.firstIndex(of: "/"),
      let version = agent[agent.index(after: slash)...].split(separator: " ").first?
        .split(separator: "-", maxSplits: 1).first
    else { return nil }
    let parts = version.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 3,
      parts.allSatisfy({ !$0.isEmpty && $0.count <= 5 && $0.utf8.allSatisfy((48...57).contains) })
    else { return nil }
    return "client_version=\(version)"
  }

  static func projectCodexHistory(_ body: inout [String: ACPJSONValue], official: Bool) {
    guard let input = body["input"]?.arrayValue else { return }
    // Bridge reasoning envelopes can also appear in sessions created by the ordinary gateway.
    body["input"] = .array(
      input.filter { item in
        guard item["type"]?.stringValue == "reasoning" else { return true }
        guard official, let value = item["encrypted_content"]?.stringValue, !value.isEmpty else {
          return false
        }
        return !value.hasPrefix("bridge-codex1:") && !value.hasPrefix("bridge-claude1:")
          && !value.hasPrefix("magpie-claude1:")
      })
  }

  static let codexInferenceHeaders: Set<String> = [
    "accept", "openai-beta", "session-id", "thread-id", "x-client-request-id",
    "x-codex-beta-features",
    "x-codex-turn-state", "x-codex-turn-metadata", "x-codex-window-id", "x-codex-parent-thread-id",
    "x-codex-installation-id", "x-codex-routing-hint", "x-openai-subagent",
    "x-openai-internal-codex-responses-lite",
  ]

  static let codexResponseHeaders: Set<String> = [
    "cache-control", "content-type", "retry-after", "www-authenticate", "x-request-id",
    "x-codex-turn-state", "x-codex-model", "x-codex-models-etag",
    "x-codex-primary-used-percent", "x-codex-primary-window-minutes", "x-codex-primary-reset-at",
    "x-codex-secondary-used-percent", "x-codex-secondary-window-minutes",
    "x-codex-secondary-reset-at",
    "x-codex-credits-has-credits", "x-codex-credits-unlimited", "x-codex-credits-balance",
  ]
}

struct CodexUpstreamEndpoints: Sendable {
  let models: URL
  let responses: URL

  static let official = Self(
    models: URL(string: "https://chatgpt.com/backend-api/codex/models")!,
    responses: URL(string: "https://chatgpt.com/backend-api/codex/responses")!)
}

struct CodexOfficialModelCache {
  struct Key: Hashable {
    private let client: String
    private let generation: UInt64
    private let identity: SHA256Digest
    private let account: String?
    private let originator: String?
    private let versionQuery: String

    init(request: ModelGatewayRequest, query: String) {
      client = request.client.clientID
      generation = request.client.generation
      // Credential changes invalidate the account-scoped cache without retaining the bearer.
      identity = SHA256.hash(data: Data((request.upstreamAuth?.authorization ?? "").utf8))
      account = request.upstreamAuth?.chatGPTAccountID
      originator = request.headers["originator"]
      versionQuery = query
    }
  }

  private struct Entry {
    let ids: Set<String>
    let expiresAt: ContinuousClock.Instant
  }

  private var entries: [Key: Entry] = [:]

  func ids(for key: Key) -> Set<String>? {
    guard let entry = entries[key], entry.expiresAt > .now else { return nil }
    return entry.ids
  }

  mutating func store(_ ids: Set<String>, for key: Key, cacheControl: String?) {
    let directives =
      cacheControl?.lowercased().split(separator: ",").map {
        $0.trimmingCharacters(in: .whitespaces)
      } ?? []
    guard !directives.contains("no-store"), !directives.contains("no-cache") else {
      entries.removeValue(forKey: key)
      return
    }
    let maxAge = directives.first { $0.hasPrefix("max-age=") }.flatMap { Int($0.dropFirst(8)) }
    let seconds = min(maxAge ?? 30, 30)
    guard seconds > 0 else {
      entries.removeValue(forKey: key)
      return
    }
    if entries[key] == nil, entries.count >= 32,
      let oldest = entries.min(by: { $0.value.expiresAt < $1.value.expiresAt })
    {
      entries.removeValue(forKey: oldest.key)
    }
    entries[key] = Entry(ids: ids, expiresAt: .now.advanced(by: .seconds(seconds)))
  }
}
