import BridgeAgentCore
import BridgeCodexRPC
import BridgeMCP
import BridgeSecurity
import Foundation

public struct ServiceCodexCatalogConfiguration: Sendable {
  public let appServer: CodexAppServerLocator
  public let clientInfo: CodexClientInfo
  public let requestTimeoutNanoseconds: UInt64
  public let eventBufferLimit: Int
  public let modelsCacheTTL: Duration

  public init(
    appServer: CodexAppServerLocator = CodexAppServerLocator(),
    clientInfo: CodexClientInfo,
    requestTimeoutNanoseconds: UInt64 = 20_000_000_000,
    eventBufferLimit: Int = 64,
    modelsCacheTTL: Duration = .seconds(300)
  ) {
    self.appServer = appServer
    self.clientInfo = clientInfo
    self.requestTimeoutNanoseconds = max(1, requestTimeoutNanoseconds)
    self.eventBufferLimit = max(1, eventBufferLimit)
    self.modelsCacheTTL = modelsCacheTTL
  }
}

public actor ServiceCodexCatalog {
  private struct ModelCacheEntry {
    let models: MCPModelList
    let fetchedAt: ContinuousClock.Instant
  }

  private struct ModelsFetch {
    let task: Task<Void, Never>
    var waiters: [UUID: CheckedContinuation<MCPModelList, any Error>] = [:]
  }

  private let configuration: ServiceCodexCatalogConfiguration
  private let clock = ContinuousClock()
  private var modelCache: ModelCacheEntry?
  /// Fetches by generation. Callers join the one of the current generation; a fetch that was
  /// invalidated meanwhile stays until it has answered the callers it already has.
  private var modelFetches: [UInt64: ModelsFetch] = [:]
  private var modelsFetchGeneration: UInt64 = 0

  public init(configuration: ServiceCodexCatalogConfiguration) {
    self.configuration = configuration
  }

  public func listThreads(
    root: String,
    cursor: String?,
    limit: Int,
    search: String?,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPThreadPage {
    guard AgentPathSemantics.isAbsolute(root), (1...100).contains(limit) else {
      throw BridgeMCPQueryError.contractRejected
    }
    return try await withClient(deadline: deadline) { client in
      let response = try await client.listThreads(
        ThreadListParams(
          cursor: cursor,
          limit: UInt32(limit),
          sortKey: "updated_at",
          sortDirection: "desc",
          archived: false,
          cwd: .anyOf([root]),
          searchTerm: search,
          useStateDbOnly: true
        )
      )
      let threads = try response.data.map { thread -> MCPThreadSummary in
        guard Self.samePath(thread.cwd, root) else { throw BridgeMCPQueryError.threadNotFound }
        return try Self.summary(thread)
      }
      return MCPThreadPage(threads: threads, nextCursor: response.nextCursor)
    }
  }

  public func listThreads(
    root: String,
    cursor: String?,
    limit: Int,
    search: String?,
    including allowedThreadIDs: Set<String>,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPThreadPage {
    guard AgentPathSemantics.isAbsolute(root), (1...100).contains(limit) else {
      throw BridgeMCPQueryError.contractRejected
    }
    let offset = try Self.decodeAppCursor(cursor)
    guard !allowedThreadIDs.isEmpty else {
      return MCPThreadPage(threads: [], nextCursor: nil)
    }

    var catalogCursor: String?
    var matching: [MCPThreadSummary] = []
    for _ in 0..<32 {
      try Self.checkDeadline(deadline)
      let page = try await listThreads(
        root: root,
        cursor: catalogCursor,
        limit: 100,
        search: search,
        deadline: deadline
      )
      matching.append(contentsOf: page.threads.filter { allowedThreadIDs.contains($0.threadID) })
      if matching.count > offset + limit || page.nextCursor == nil {
        let end = min(offset + limit, matching.count)
        guard offset <= end else { throw BridgeMCPQueryError.contractRejected }
        let next = end < matching.count ? "app.v1.\(end)" : nil
        return MCPThreadPage(threads: Array(matching[offset..<end]), nextCursor: next)
      }
      guard page.nextCursor != catalogCursor else { throw BridgeMCPQueryError.unavailable }
      catalogCursor = page.nextCursor
    }
    throw BridgeMCPQueryError.unavailable
  }

  public func readThread(
    root: String,
    threadID: String,
    detail: MCPThreadDetail,
    cursor: String?,
    limit: Int,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPThreadReadPage {
    guard AgentPathSemantics.isAbsolute(root),
      Self.validIdentifier(threadID, maximum: 1_024), (1...100).contains(limit)
    else {
      throw BridgeMCPQueryError.contractRejected
    }
    return try await withClient(deadline: deadline) { client in
      let response: ThreadReadResponse
      do {
        response = try await client.readThread(
          ThreadReadParams(threadId: threadID, includeTurns: detail == .full)
        )
      } catch let error as CodexRPCError {
        throw Self.publicThreadReadError(error)
      }
      guard response.thread.id == threadID, Self.samePath(response.thread.cwd, root) else {
        throw BridgeMCPQueryError.threadNotFound
      }
      let summary = try Self.summary(response.thread)
      guard detail == .full else {
        guard cursor == nil else { throw BridgeMCPQueryError.contractRejected }
        return MCPThreadReadPage(thread: summary, detail: detail, entries: [])
      }
      let entries = try response.thread.turns.flatMap(Self.entries)
      let offset = try Self.decodeCursor(cursor, maximum: entries.count)
      let end = min(offset + limit, entries.count)
      let page = Array(entries[offset..<end])
      let next = end < entries.count ? "v1.\(end)" : nil
      return MCPThreadReadPage(
        thread: summary,
        detail: detail,
        entries: page,
        nextCursor: next
      )
    }
  }

  private static func publicThreadReadError(_ error: CodexRPCError) -> Error {
    switch error {
    case .remote(_, let message, _)
    where message == "thread not loaded" || message.hasPrefix("invalid thread id"):
      return BridgeMCPQueryError.threadNotFound
    case .timeout:
      return BridgeMCPQueryError.timeout
    default:
      return error
    }
  }

  public func listModels(deadline: ContinuousClock.Instant) async throws -> MCPModelList {
    try Self.checkDeadline(deadline)
    if let cache = modelCache, clock.now < cache.fetchedAt + configuration.modelsCacheTTL {
      return cache.models
    }
    let generation = joinModelsFetch()
    let waiterID = UUID()
    // A caller leaves at its own deadline. The fetch is bounded by the request timeout, so it
    // may still finish and fill the cache for the next caller.
    let expiry = Task { [clock] in
      guard (try? await clock.sleep(until: deadline)) != nil else { return }
      self.takeModelsWaiter(waiterID, generation: generation)?
        .resume(throwing: BridgeMCPQueryError.timeout)
    }
    defer { expiry.cancel() }
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        modelFetches[generation]?.waiters[waiterID] = continuation
      }
    } onCancel: {
      Task { await self.cancelModelsWaiter(waiterID, generation: generation) }
    }
  }

  /// Single flight: concurrent callers share one app-server spawn instead of starting one cold
  /// process per request. Returns the generation of the fetch to wait for.
  private func joinModelsFetch() -> UInt64 {
    if modelFetches[modelsFetchGeneration] == nil {
      modelsFetchGeneration += 1
      modelFetches[modelsFetchGeneration] = ModelsFetch(
        task: makeModelsFetchTask(generation: modelsFetchGeneration))
    }
    return modelsFetchGeneration
  }

  private func finishModelsFetch(generation: UInt64, result: Result<MCPModelList, any Error>) {
    guard let fetch = modelFetches.removeValue(forKey: generation) else { return }
    if case .success(let models) = result, generation == modelsFetchGeneration {
      modelCache = ModelCacheEntry(models: models, fetchedAt: clock.now)
    }
    for waiter in fetch.waiters.values { waiter.resume(with: result) }
  }

  private func takeModelsWaiter(_ waiterID: UUID, generation: UInt64)
    -> CheckedContinuation<MCPModelList, any Error>?
  {
    modelFetches[generation]?.waiters.removeValue(forKey: waiterID)
  }

  /// A cancelled caller that was the last one waiting takes the fetch and its process down with it.
  private func cancelModelsWaiter(_ waiterID: UUID, generation: UInt64) {
    guard let waiter = takeModelsWaiter(waiterID, generation: generation) else { return }
    if modelFetches[generation]?.waiters.isEmpty == true {
      modelFetches.removeValue(forKey: generation)?.task.cancel()
    }
    waiter.resume(throwing: CancellationError())
  }

  public func refreshModels(deadline: ContinuousClock.Instant) async throws -> MCPModelList {
    invalidateModelCache()
    return try await listModels(deadline: deadline)
  }

  /// Drops cached models without fetching, so the next request uses a re-resolved
  /// app-server configuration.
  public func invalidateModelCache() {
    modelCache = nil
    modelsFetchGeneration += 1
  }

  private func makeModelsFetchTask(generation: UInt64) -> Task<Void, Never> {
    let configuration = self.configuration
    let fetchDeadline =
      clock.now
      .advanced(by: .nanoseconds(Int64(clamping: configuration.requestTimeoutNanoseconds)))
    return Task {
      let result: Result<MCPModelList, any Error>
      do {
        result = .success(
          try await Self.fetchModels(configuration: configuration, deadline: fetchDeadline))
      } catch {
        result = .failure(error)
      }
      self.finishModelsFetch(generation: generation, result: result)
    }
  }

  private static func fetchModels(
    configuration: ServiceCodexCatalogConfiguration,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPModelList {
    var refreshFailure: String?
    var fallbackModels: [CodexModel] = []
    for attempt in 0..<2 {
      let outcome = try await withClient(configuration: configuration, deadline: deadline) {
        client in
        try await ServiceCodexCatalogModelFetch.models(client: client, deadline: deadline)
      }
      switch outcome {
      case .models(let models):
        return try projectModels(models)
      case .refreshFailed(let detail, let fallback):
        refreshFailure = detail
        if !fallback.isEmpty {
          fallbackModels = fallback
        }
        if attempt == 0,
          fallbackModels.isEmpty || ContinuousClock.now.duration(to: deadline) >= .seconds(6)
        {
          try await Task.sleep(for: .milliseconds(500))
          try checkDeadline(deadline)
        } else {
          break
        }
      }
    }
    if !fallbackModels.isEmpty {
      return try projectModels(fallbackModels)
    }
    throw BridgeMCPQueryError.codexAppServerUnavailable(
      "Codex could not refresh its model catalog. \(refreshFailure ?? "No native refresh diagnostic was provided.")"
    )
  }

  private static func projectModels(_ models: [CodexModel]) throws -> MCPModelList {
    MCPModelList(
      models: try models.enumerated().map {
        try ServiceCodexCatalogModelProjection.model($0.element, index: $0.offset)
      })
  }

  private func withClient<Output: Sendable>(
    deadline: ContinuousClock.Instant,
    operation: @escaping @Sendable (CodexAppServerClient) async throws -> Output
  ) async throws -> Output {
    try await Self.withClient(
      configuration: configuration,
      deadline: deadline,
      operation: operation
    )
  }

  private static func withClient<Output: Sendable>(
    configuration: ServiceCodexCatalogConfiguration,
    deadline: ContinuousClock.Instant,
    operation: @escaping @Sendable (CodexAppServerClient) async throws -> Output
  ) async throws -> Output {
    try checkDeadline(deadline)
    let appServer = configuration.appServer.current()
    let client = CodexAppServerClient(
      configuration: appServer,
      defaultTimeoutNanoseconds: configuration.requestTimeoutNanoseconds,
      eventBufferLimit: configuration.eventBufferLimit
    )
    let drain = Task {
      for await event in client.events {
        guard case .serverRequest(let request) = event else { continue }
        try? await client.respond(
          to: request.id,
          errorCode: -32601,
          message: "The read-only catalog cannot approve operations."
        )
      }
    }
    do {
      try await client.start()
      _ = try await client.initialize(clientInfo: configuration.clientInfo)
      let output = try await operation(client)
      try checkDeadline(deadline)
      drain.cancel()
      await client.stop()
      return output
    } catch is CancellationError {
      drain.cancel()
      await client.stop()
      throw CancellationError()
    } catch let error as BridgeMCPQueryError {
      drain.cancel()
      await client.stop()
      throw error
    } catch let error as CodexRPCError {
      let stderr = await client.stderrSnapshot()
      drain.cancel()
      await client.stop()
      guard
        let detail = Self.appServerFailureDetail(error, appServer: appServer, stderr: stderr)
      else { throw BridgeMCPQueryError.unavailable }
      throw BridgeMCPQueryError.codexAppServerUnavailable(detail)
    } catch {
      drain.cancel()
      await client.stop()
      throw BridgeMCPQueryError.unavailable
    }
  }

  /// Renders why the app-server could not serve the request, so a user who
  /// configured an executable path is told which binary Bridge tried and what
  /// the process reported instead of a generic unavailability. Error replies
  /// from a healthy app-server keep their existing mapping.
  private static func appServerFailureDetail(
    _ error: CodexRPCError,
    appServer: AppServerConfiguration,
    stderr: Data
  ) -> String? {
    guard case .remote = error else {
      var detail: String
      if let reason = appServer.launchFailureReason {
        detail = reason
      } else {
        detail = "\(error.localizedDescription) (executable: \(appServer.executableURL.path))"
      }
      if let excerpt = stderrExcerpt(stderr) {
        detail += "; stderr: \(excerpt)"
      }
      return OutboundContentSecurity.redactedSecrets(detail, maximumUTF8Bytes: 512)
    }
    return nil
  }

  private static func stderrExcerpt(_ stderr: Data) -> String? {
    guard let text = String(data: stderr, encoding: .utf8) else { return nil }
    let lines = text.split(whereSeparator: \.isNewline).map(String.init)
    guard let line = lines.last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
    else { return nil }
    return String(line.trimmingCharacters(in: .whitespaces).prefix(240))
  }

  private static func summary(_ source: CodexThread) throws -> MCPThreadSummary {
    try validateIdentifier(source.id, maximum: 1_024)
    let title = safeOptional(source.name, maximum: 1_024)
    let preview = safeOptional(source.preview, maximum: 4 * 1_024)
    let status =
      source.status.stringValue
      ?? source.status.objectValue?["type"]?.stringValue
      ?? "unknown"
    try validateIdentifier(status, maximum: 128)
    return MCPThreadSummary(
      threadID: source.id,
      title: title,
      status: status,
      updatedAt: source.updatedAt >= 0
        ? ISO8601DateFormatter().string(
          from: Date(timeIntervalSince1970: TimeInterval(source.updatedAt))
        ) : nil,
      preview: preview
    )
  }

  private static func entries(_ turn: CodexTurn) throws -> [MCPThreadEntry] {
    try validateIdentifier(turn.id, maximum: 1_024)
    var result: [MCPThreadEntry] = []
    for item in turn.items {
      guard let object = item.objectValue,
        let type = object["type"]?.stringValue,
        let text = messageText(object)
      else { continue }
      let role: String
      switch type {
      case "agentMessage": role = "assistant"
      case "userMessage": role = "user"
      default: continue
      }
      let safeText = OutboundContentSecurity.redacted(text, maximumUTF8Bytes: 32 * 1_024)
      guard !safeText.isEmpty else { continue }
      result.append(
        MCPThreadEntry(
          turnID: turn.id,
          role: role,
          text: safeText,
          status: safeOptional(turn.status, maximum: 128)
        )
      )
      guard result.count <= 1_000 else { throw BridgeMCPQueryError.unavailable }
    }
    return result
  }

  private static func messageText(_ object: [String: JSONValue]) -> String? {
    if let text = object["text"]?.stringValue { return text }
    guard case .array(let content)? = object["content"] else { return nil }
    let text = content.compactMap { value in
      value.objectValue?["text"]?.stringValue
    }.joined(separator: "\n")
    return text.isEmpty ? nil : text
  }

  private static func decodeCursor(_ cursor: String?, maximum: Int) throws -> Int {
    guard let cursor else { return 0 }
    let parts = cursor.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 2, parts[0] == "v1", let value = Int(parts[1]),
      value >= 0, value <= maximum
    else {
      throw BridgeMCPQueryError.contractRejected
    }
    return value
  }

  private static func decodeAppCursor(_ cursor: String?) throws -> Int {
    guard let cursor else { return 0 }
    guard cursor.hasPrefix("app.v1."), let offset = Int(cursor.dropFirst(7)), offset >= 0 else {
      throw BridgeMCPQueryError.contractRejected
    }
    return offset
  }

  private static func safeOptional(_ value: String?, maximum: Int) -> String? {
    guard let value else { return nil }
    let safe = OutboundContentSecurity.redacted(value, maximumUTF8Bytes: maximum)
    return safe.isEmpty ? nil : safe
  }

  private static func samePath(_ lhs: String, _ rhs: String) -> Bool {
    AgentPathSemantics.isContained(lhs, in: rhs)
      && AgentPathSemantics.isContained(rhs, in: lhs)
  }

  private static func validIdentifier(_ value: String, maximum: Int) -> Bool {
    do {
      try validateIdentifier(value, maximum: maximum)
      return true
    } catch {
      return false
    }
  }

  private static func validateIdentifier(_ value: String, maximum: Int) throws {
    guard !value.isEmpty,
      value == value.trimmingCharacters(in: .whitespacesAndNewlines),
      value.utf8.count <= maximum,
      !value.contains("\0"),
      value.rangeOfCharacter(from: .controlCharacters) == nil,
      OutboundContentSecurity.isSafe(value)
    else {
      throw BridgeMCPQueryError.unavailable
    }
  }

  private static func checkDeadline(_ deadline: ContinuousClock.Instant) throws {
    guard ContinuousClock.now < deadline else { throw BridgeMCPQueryError.timeout }
  }
}
