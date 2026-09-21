import BridgeFiles
import BridgeMCP
import Foundation

struct StoredDirectMutation: Sendable {
  enum State: Sendable {
    case pending
    case applied
    case undone
  }

  let operationID: String
  let request: MCPDirectMutationRequest
  let prepared: PreparedProjectMutation
  let createdAt: Date
  var state: State

  var byteCount: Int {
    prepared.changedFiles.reduce(0) { total, file in
      total + (file.beforeContent?.count ?? 0) + file.afterContent.count
    }
  }
}

actor DirectMutationOperationStore {
  private let maximumOperations = 32
  private let maximumBytes = 16 * 1_024 * 1_024
  private var operations: [String: StoredDirectMutation] = [:]

  func insertPending(
    operationID: String,
    request: MCPDirectMutationRequest,
    prepared: PreparedProjectMutation
  ) {
    prune()
    operations[operationID] = StoredDirectMutation(
      operationID: operationID,
      request: request,
      prepared: prepared,
      createdAt: Date(),
      state: .pending
    )
    trimToBounds()
  }

  func insertApplied(
    operationID: String,
    request: MCPDirectMutationRequest,
    prepared: PreparedProjectMutation
  ) {
    prune()
    operations[operationID] = StoredDirectMutation(
      operationID: operationID,
      request: request,
      prepared: prepared,
      createdAt: Date(),
      state: .applied
    )
    trimToBounds()
  }

  func operation(_ operationID: String) -> StoredDirectMutation? {
    prune()
    return operations[operationID]
  }

  func markApplied(_ operationID: String) -> StoredDirectMutation? {
    guard var operation = operations[operationID], case .pending = operation.state else {
      return nil
    }
    operation.state = .applied
    operations[operationID] = operation
    return operation
  }

  func markUndone(_ operationID: String) -> StoredDirectMutation? {
    guard var operation = operations[operationID], case .applied = operation.state else {
      return nil
    }
    operation.state = .undone
    operations[operationID] = operation
    return operation
  }

  private func prune() {
    let expiry = Date().addingTimeInterval(-60 * 60)
    operations = operations.filter { $0.value.createdAt >= expiry }
  }

  private func trimToBounds() {
    while operations.count > maximumOperations || totalBytes > maximumBytes {
      guard let oldest = operations.values.min(by: { $0.createdAt < $1.createdAt }) else { return }
      operations.removeValue(forKey: oldest.operationID)
    }
  }

  private var totalBytes: Int {
    operations.values.reduce(0) { $0 + $1.byteCount }
  }
}
