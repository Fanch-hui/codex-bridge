import BridgeAgentCore
import BridgeIPC
import Foundation

struct ServiceAgentSetupVerification: Sendable {
  let installationID: String
  let version: String?
  let message: String
}

struct ServiceAgentSetupDependencies: Sendable {
  let candidates: @Sendable (IPCAgentSetupRequest) async throws -> [IPCAgentSetupCandidate]
  let configure: @Sendable (IPCAgentSetupRequest, ServiceAgentSetupRuntime) async throws -> Void
  let verify:
    @Sendable (IPCAgentSetupRequest, ServiceAgentSetupRuntime, IPCAgentSetupContinueRequest?)
      async
      throws -> ServiceAgentSetupVerification
  let login:
    @Sendable (IPCAgentSetupRequest, ServiceAgentSetupRuntime) throws
      -> IPCAgentSetupLoginCommand?
}

enum ServiceAgentSetupError: LocalizedError, Sendable {
  case invalidRequest
  case operationNotFound
  case unavailable(String)
  case userAction(String)

  var errorDescription: String? {
    switch self {
    case .invalidRequest: "一键配置参数无效。"
    case .operationNotFound: "配置操作不存在，请重新开始。"
    case .unavailable(let message), .userAction(let message): message
    }
  }
}

actor ServiceAgentSetupCoordinator {
  struct Operation: Codable {
    var request: IPCAgentSetupRequest
    var snapshot: IPCAgentSetupState
    var runtime: ServiceAgentSetupRuntime?
    var permissionConfirmed: Bool?
  }

  let defaultRoot: URL
  let cacheURL: URL
  let installer: any ServiceAgentSetupInstalling
  let dependencies: ServiceAgentSetupDependencies
  var operations: [String: Operation]
  var workers: [String: Task<Void, Never>] = [:]
  var stopped = false

  init(
    defaultRoot: URL, cacheURL: URL,
    installer: any ServiceAgentSetupInstalling = ServiceAgentSetupInstaller(),
    dependencies: ServiceAgentSetupDependencies
  ) {
    self.defaultRoot = defaultRoot
    self.cacheURL = cacheURL
    self.installer = installer
    self.dependencies = dependencies
    self.operations = Self.restore(from: cacheURL)
  }

  func snapshots() -> [IPCAgentSetupState] {
    operations.values.map(\.snapshot).sorted {
      ($0.providerID, $0.distribution ?? "") < ($1.providerID, $1.distribution ?? "")
    }
  }

  func begin(_ request: IPCAgentSetupRequest) throws -> IPCAgentSetupState {
    try Self.validate(request)
    guard !stopped else { throw CancellationError() }
    if let previous = operations.values.first(where: {
      $0.request.providerID == request.providerID
        && $0.request.qoderDistribution == request.qoderDistribution
    }) {
      let id = previous.snapshot.operationID
      if workers[id] != nil || previous.snapshot.state == "needs_user_action" {
        return previous.snapshot
      }
      operations.removeValue(forKey: id)
    }
    let id = UUID().uuidString.lowercased()
    let snapshot = IPCAgentSetupState(
      operationID: id, providerID: request.providerID, distribution: request.qoderDistribution)
    operations[id] = Operation(request: request, snapshot: snapshot)
    try persist()
    workers[id] = Task { await prepare(id) }
    return snapshot
  }

  func resume(_ request: IPCAgentSetupContinueRequest) throws -> IPCAgentSetupState {
    let id = request.operationID
    guard !stopped, var operation = operations[id] else {
      throw ServiceAgentSetupError.operationNotFound
    }
    guard workers[id] == nil else { return operation.snapshot }
    guard operation.snapshot.state == "needs_user_action" else {
      throw ServiceAgentSetupError.invalidRequest
    }
    if operation.snapshot.userAction == "select_installation" {
      guard let selected = request.installationID,
        operation.snapshot.candidates.contains(where: { $0.installationID == selected })
      else { throw ServiceAgentSetupError.invalidRequest }
      operation.request = IPCAgentSetupRequest(
        providerID: operation.request.providerID,
        qoderDistribution: operation.request.qoderDistribution, installationID: selected,
        installDirectory: operation.request.installDirectory)
      operation.snapshot.state = "checking"
      operation.snapshot.userAction = nil
      operations[id] = operation
      try persist()
      workers[id] = Task { await prepare(id) }
    } else {
      if operation.snapshot.userAction == "permission", !request.alwaysProceedConfirmed {
        throw ServiceAgentSetupError.invalidRequest
      }
      guard operation.runtime != nil else { throw ServiceAgentSetupError.invalidRequest }
      let completedLogin = operation.snapshot.userAction == "login"
      if operation.snapshot.userAction == "permission" {
        operation.permissionConfirmed = true
      }
      let input = IPCAgentSetupContinueRequest(
        operationID: id, installationID: request.installationID,
        baseURL: request.baseURL, apiKey: request.apiKey,
        inferenceProtocol: request.inferenceProtocol, catalogBaseURL: request.catalogBaseURL,
        alwaysProceedConfirmed: operation.permissionConfirmed == true,
        loginCompleted: completedLogin)
      operation.snapshot.state = "verifying"
      operation.snapshot.message = "正在验证连接并读取模型目录…"
      operation.snapshot.userAction = nil
      operations[id] = operation
      try persist()
      workers[id] = Task {
        await verify(id, input: input)
        workers.removeValue(forKey: id)
      }
    }
    return operations[id]!.snapshot
  }

  func cancel(_ id: String) throws -> IPCAgentSetupState {
    guard var operation = operations[id] else { throw ServiceAgentSetupError.operationNotFound }
    workers[id]?.cancel()
    operation.snapshot.state = "cancelled"
    operation.snapshot.message = "配置已取消。已完成的安装可以在重试时复用。"
    operation.snapshot.userAction = nil
    operations[id] = operation
    try persist()
    return operation.snapshot
  }

  func shutdown() async {
    stopped = true
    let active = workers
    for (id, worker) in active {
      worker.cancel()
      if operations[id]?.snapshot.isRunning == true {
        update(id, state: "interrupted", message: "配置已中断，请重新开始。")
      }
    }
    for worker in active.values { await worker.value }
  }

  func update(
    _ id: String, state: String? = nil, message: String,
    userAction: String? = nil
  ) {
    guard var operation = operations[id],
      !["cancelled", "interrupted"].contains(operation.snapshot.state)
    else { return }
    if let state { operation.snapshot.state = state }
    operation.snapshot.message = message
    operation.snapshot.userAction = userAction
    operations[id] = operation
    do { try persist() } catch { workers[id]?.cancel() }
  }

  func persist() throws {
    try FileManager.default.createDirectory(
      at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONEncoder().encode(Array(operations.values)).write(to: cacheURL, options: .atomic)
  }

  static func restore(from url: URL) -> [String: Operation] {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return [:] }
    defer { try? handle.close() }
    guard let data = try? handle.read(upToCount: 262_145), data.count <= 262_144,
      let saved = try? JSONDecoder().decode([Operation].self, from: data)
    else { return [:] }
    var result: [String: Operation] = [:]
    for var operation in saved {
      guard (try? validate(operation.request)) != nil else { continue }
      if operation.snapshot.isRunning {
        operation.snapshot.state = "interrupted"
        operation.snapshot.message = "配置已中断，请重新开始。"
      }
      result[operation.snapshot.operationID] = operation
    }
    return result
  }

  static func validate(_ request: IPCAgentSetupRequest) throws {
    guard
      ["opencode", "deepseek-harness", "antigravity", "pi", "qoder"].contains(request.providerID),
      request.providerID == "qoder"
        ? request.qoderDistribution.flatMap(QoderDistribution.init(rawValue:)) != nil
        : request.qoderDistribution == nil
    else { throw ServiceAgentSetupError.invalidRequest }
    if let path = request.installDirectory {
      guard AgentPathSemantics.isAbsolute(path), path.utf8.count <= 16_384,
        path.rangeOfCharacter(from: .controlCharacters) == nil
      else { throw ServiceAgentSetupError.invalidRequest }
    }
  }
}
