import BridgeIPC
import BridgeMCP
import BridgeServiceCore
import Foundation

actor ServiceGeminiCloudController {
  nonisolated let accessGate = GeminiCloudAccessGate()
  private let settings: ServiceSettings
  private let clients: ServiceMCPClientRegistry
  private let mutationGate = AsyncMutex()
  private var lifecycle = "stopped"
  private var message: String?
  private var lastConnectedAt: Date?
  private var generation = UUID()
  private var pollTask: Task<Void, Never>?
  private var requests: [String: Task<Void, Never>] = [:]
  private var transport: GeminiSitesRelayTransport?

  init(settings: ServiceSettings, clients: ServiceMCPClientRegistry) {
    self.settings = settings
    self.clients = clients
  }

  func status() async throws -> IPCGeminiCloudStatus {
    let saved = try await savedConfiguration()
    return .init(
      configuration: saved, lifecycle: lifecycle, message: message,
      lastConnectedAt: lastConnectedAt.map { ISO8601DateFormatter().string(from: $0) })
  }

  func configure(_ value: IPCGeminiCloudConfiguration, endpoint: URL) async throws {
    await mutationGate.acquire()
    defer { mutationGate.release() }
    let normalized = try Self.normalized(value)
    let data = try JSONEncoder().encode(normalized)
    try await settings.set(String(decoding: data, as: UTF8.self), for: .geminiCloudConfiguration)
    await restart(normalized, endpoint: endpoint)
  }

  func synchronize(endpoint: URL?) async {
    await mutationGate.acquire()
    defer { mutationGate.release() }
    do {
      await restart(try await savedConfiguration(), endpoint: endpoint)
    } catch {
      await stopRuntime()
      lifecycle = "failed"
      message = "云 MCP 配置读取失败，请重新保存连接设置。"
    }
  }

  func shutdown() async {
    await mutationGate.acquire()
    defer { mutationGate.release() }
    await stopRuntime()
    lifecycle = "stopped"
  }

  func export(_ kind: IPCGeminiCloudExportKind, endpoint: URL) async throws -> String {
    switch kind {
    case .endpoint:
      guard let value = try await savedConfiguration() else { throw GeminiCloudError.notConfigured }
      let credential = try await clients.credential(for: .gemini)
      return value.baseURL + "/gemini-mcp/" + GeminiCloudCredentials.accessKey(for: credential)
    case .sitesEnvironment:
      let credential = try await clients.credential(for: .gemini)
      let environment = [
        "BRIDGE_MCP_KEY": GeminiCloudCredentials.accessKey(for: credential),
        "BRIDGE_RELAY_KEY": GeminiCloudCredentials.relayKey(for: credential),
      ]
      return String(
        decoding: try JSONSerialization.data(
          withJSONObject: environment, options: [.prettyPrinted, .sortedKeys]),
        as: UTF8.self)
    case .sitesPrompt:
      return GeminiSitesSetupGuide.prompt
    case .ngrokCommand:
      guard let port = endpoint.port else { throw GeminiCloudError.notConfigured }
      return "ngrok http http://127.0.0.1:\(port) --inspect=false"
    }
  }

  private func savedConfiguration() async throws -> IPCGeminiCloudConfiguration? {
    guard let raw = try await settings.string(for: .geminiCloudConfiguration) else { return nil }
    return try Self.normalized(
      JSONDecoder().decode(IPCGeminiCloudConfiguration.self, from: Data(raw.utf8)))
  }

  static func normalized(_ value: IPCGeminiCloudConfiguration) throws -> IPCGeminiCloudConfiguration
  {
    let trimmed = value.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    guard var parts = URLComponents(string: trimmed), parts.scheme?.lowercased() == "https",
      let host = parts.host?.lowercased(), !host.isEmpty,
      host != "localhost", !host.hasSuffix(".localhost"), !host.contains(":"),
      host.contains("."), !host.allSatisfy({ $0.isNumber || $0 == "." }),
      parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
      parts.path.isEmpty || parts.path == "/", parts.port == nil || parts.port == 443,
      value.hosting != .sites || host.hasSuffix(".chatgpt.site")
    else { throw GeminiCloudError.invalidAddress }
    parts.scheme = "https"
    parts.host = host
    parts.path = ""
    parts.port = nil
    guard let baseURL = parts.url?.absoluteString else { throw GeminiCloudError.invalidAddress }
    return .init(hosting: value.hosting, baseURL: baseURL, enabled: value.enabled)
  }

  private func restart(_ value: IPCGeminiCloudConfiguration?, endpoint: URL?) async {
    await stopRuntime()
    message = nil
    lastConnectedAt = nil
    guard let value, value.enabled else {
      lifecycle = "stopped"
      return
    }
    guard let endpoint else {
      lifecycle = "failed"
      message = "本机 MCP 服务尚未就绪。"
      return
    }
    do {
      let credential = try await clients.credential(for: .gemini)
      if value.hosting == .ngrok {
        accessGate.setEnabled(true)
        lifecycle = "configured"
        return
      }
      guard let baseURL = URL(string: value.baseURL) else { throw GeminiCloudError.invalidAddress }
      let transport = GeminiSitesRelayTransport(
        baseURL: baseURL, relayKey: GeminiCloudCredentials.relayKey(for: credential),
        endpoint: endpoint, credential: credential)
      self.transport = transport
      lifecycle = "connecting"
      let generation = generation
      pollTask = Task { [weak self] in await self?.poll(transport, generation: generation) }
    } catch ServiceMCPClientRegistryError.clientDisabled {
      lifecycle = "client_disabled"
      message = "请先启用 Gemini 连接。"
    } catch {
      lifecycle = "failed"
      message = "无法准备 Gemini 云 MCP 凭据，请检查系统凭据存储后重试。"
    }
  }

  private func stopRuntime() async {
    accessGate.setEnabled(false)
    generation = UUID()
    let poll = pollTask
    pollTask = nil
    poll?.cancel()
    let pending = Array(requests.values)
    requests.removeAll()
    for task in pending { task.cancel() }
    transport?.close()
    transport = nil
    await poll?.value
    for task in pending { await task.value }
  }

  private func poll(_ transport: GeminiSitesRelayTransport, generation: UUID) async {
    var delay = 1
    while !Task.isCancelled, generation == self.generation {
      do {
        let available = 4 - requests.count
        if available > 0 {
          let jobs = try await transport.poll(limit: available)
          guard generation == self.generation, !Task.isCancelled else { return }
          lifecycle = "ready"
          message = nil
          lastConnectedAt = Date()
          for job in jobs where requests[job.id] == nil {
            requests[job.id] = Task { [weak self] in
              let result = await transport.forward(job)
              if !Task.isCancelled {
                await self?.complete(result, transport: transport, generation: generation)
              }
              await self?.finished(job.id, generation: generation)
            }
          }
        }
        delay = 1
      } catch {
        guard generation == self.generation, !Task.isCancelled else { return }
        lifecycle = "failed"
        message =
          (error as? GeminiCloudError)?.errorDescription
          ?? "Sites 连接暂不可用，正在重连；请检查网络与网站部署状态。"
        delay = min(delay * 2, 30)
      }
      try? await Task.sleep(for: .seconds(delay))
    }
  }

  private func complete(
    _ result: GeminiSitesRelayCompletion, transport: GeminiSitesRelayTransport, generation: UUID
  ) async {
    for attempt in 0..<3 {
      guard generation == self.generation, !Task.isCancelled else { return }
      do {
        try await transport.complete(result)
        return
      } catch {
        if attempt < 2 { try? await Task.sleep(for: .seconds(1)) }
      }
    }
    if generation == self.generation {
      message = "Sites 结果回传失败；操作不会重复执行，请在 Bridge 中检查执行结果。"
    }
  }

  private func finished(_ id: String, generation: UUID) {
    if generation == self.generation { requests.removeValue(forKey: id) }
  }
}
