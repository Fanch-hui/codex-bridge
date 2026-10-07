import BridgeIPC
import Foundation

public struct DirectCommandCheckStatus: Equatable, Sendable {
  public var isChecking = false
  public var projectID: String?
  public var commandLine = ""
  public var workingDirectory = ""
  public var result: IPCDirectCommandCheckResult?
  public var errorMessage: String?

  public init() {}
}

@MainActor
public final class DirectCommandCheckController {
  public private(set) var state = DirectCommandCheckStatus() {
    didSet { if oldValue != state { onChange() } }
  }

  private let client: @MainActor () throws -> any BridgeServiceClientProtocol
  private let onChange: @MainActor () -> Void
  private var generation: UInt64 = 0
  private var operation: Task<Void, Never>?

  public init(
    client: @escaping @MainActor () throws -> any BridgeServiceClientProtocol,
    onChange: @escaping @MainActor () -> Void
  ) {
    self.client = client
    self.onChange = onChange
  }

  public func check(_ request: IPCDirectCommandCheckRequest) {
    invalidate()
    let currentGeneration = generation
    state.projectID = request.projectID
    state.commandLine = request.commandLine
    state.workingDirectory = request.workingDirectory ?? ""
    state.isChecking = true
    operation = Task { [weak self] in
      guard let self else { return }
      defer {
        if generation == currentGeneration {
          state.isChecking = false
          operation = nil
        }
      }
      do {
        let result = try await client().checkDirectCommand(request)
        guard generation == currentGeneration, !Task.isCancelled else { return }
        guard result.projectID == request.projectID, result.requestID == request.requestID else {
          state.errorMessage = "命令校验回执与当前请求不一致，请重新校验。"
          return
        }
        state.result = result
      } catch {
        guard generation == currentGeneration, !Task.isCancelled else { return }
        state.errorMessage = "命令校验失败：\(BridgeServiceErrorMessage.message(error))"
      }
    }
  }

  public func invalidate() {
    generation &+= 1
    operation?.cancel()
    operation = nil
    state = DirectCommandCheckStatus()
  }
}
