import BridgeIPC

@MainActor
public final class WorkbenchWorkspaceModel {
  public private(set) var state = WorkbenchWorkspaceState() {
    didSet { if oldValue != state { onChange() } }
  }

  private let client: @MainActor () throws -> any BridgeServiceClientProtocol
  private let onChange: @MainActor () -> Void
  private var generation: UInt64 = 0
  private var requests: [String: String] = [:]

  public init(
    client: @escaping @MainActor () throws -> any BridgeServiceClientProtocol,
    onChange: @escaping @MainActor () -> Void
  ) {
    self.client = client
    self.onChange = onChange
  }

  public convenience init(
    client: any BridgeServiceClientProtocol, onChange: @escaping @MainActor () -> Void = {}
  ) {
    self.init(client: { client }, onChange: onChange)
  }

  public func selectProject(_ projectID: String?) {
    guard state.projectID != projectID else { return }
    generation &+= 1
    requests.removeAll()
    state = WorkbenchWorkspaceState(projectID: projectID)
  }

  public static let serviceUnavailableMessage = "后台服务暂时无法连接，连接恢复后会自动重新读取。"

  public func reject(requestID: String, message: String, errorCode: String? = nil) {
    state.lastRequestID = requestID
    state.errorMessage = message
    state.errorCode = errorCode
  }

  /// Answers a request the host could not forward because the service connection is down.
  public func rejectUnavailable(requestID: String) {
    reject(
      requestID: requestID, message: Self.serviceUnavailableMessage,
      errorCode: BridgeServiceErrorMessage.serviceUnavailableCode)
  }

  public func perform(_ request: IPCWorkbenchWorkspaceRequest) async {
    guard request.projectID == state.projectID else {
      reject(requestID: request.clientRequestID, message: "项目已变化，请重新选择文件。")
      return
    }
    let lane = lane(for: request.action)
    let currentGeneration = generation
    requests[lane] = request.clientRequestID
    prepare(request)
    do {
      let response = try await client().workbenchWorkspace(request)
      guard current(request, lane: lane, generation: currentGeneration) else { return }
      guard response.projectID == request.projectID, response.action == request.action else {
        throw BridgeServiceIPCCodecError.requestMismatch
      }
      merge(response)
      state.errorMessage = nil
      state.errorCode = nil
    } catch {
      guard current(request, lane: lane, generation: currentGeneration) else { return }
      if BridgeServiceErrorMessage.isServiceUnavailable(error) {
        state.errorMessage = Self.serviceUnavailableMessage
        state.errorCode = BridgeServiceErrorMessage.serviceUnavailableCode
      } else {
        state.errorMessage = BridgeServiceErrorMessage.message(error)
        state.errorCode = BridgeServiceErrorMessage.remoteFailure(error)?.code
      }
    }
    requests.removeValue(forKey: lane)
    state.isLoading = !requests.isEmpty
    state.lastRequestID = request.clientRequestID
  }

  private func current(
    _ request: IPCWorkbenchWorkspaceRequest, lane: String, generation: UInt64
  ) -> Bool {
    self.generation == generation && requests[lane] == request.clientRequestID
  }

  private func lane(for action: IPCWorkbenchWorkspaceAction) -> String {
    switch action {
    case .listDirectory: "directory"
    case .gitStatus: "git"
    case .readFile, .gitDiff, .previewWrite, .applyWrite: "file"
    }
  }

  private func prepare(_ request: IPCWorkbenchWorkspaceRequest) {
    if state.lastRequestID == request.clientRequestID { state.lastRequestID = nil }
    state.isLoading = true
    state.errorMessage = nil
    state.errorCode = nil
    if request.action == .readFile || request.action == .gitDiff {
      if state.selectedPath != request.relativePath {
        state.file = nil
        state.diff = nil
        state.preview = nil
        state.mutation = nil
      }
      state.selectedPath = request.relativePath
    }
    if request.action == .previewWrite {
      state.preview = nil
      state.mutation = nil
    }
  }

  private func merge(_ response: IPCWorkbenchWorkspaceResponse) {
    if let directory = response.directory { state.directory = directory }
    if let file = response.file { state.file = file }
    if let git = response.git { state.git = git }
    if let diff = response.diff { state.diff = diff }
    if let preview = response.preview { state.preview = preview }
    if let mutation = response.mutation {
      state.mutation = mutation
      state.preview = nil
    }
  }
}
