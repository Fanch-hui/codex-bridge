import Foundation

struct ModelReadWaiter {
  let id: UUID
  let continuation: CheckedContinuation<Void, any Error>
}

extension BridgeServiceClient {
  func performModelRead<Response: Decodable>(
    _ data: Data, requestID: String
  ) async throws -> Response {
    try await acquireModelRead()
    defer { releaseModelRead() }
    var attempt = 0
    while true {
      try Task.checkCancellation()
      guard !invalidated else { throw BridgeServiceClientError.unavailable }
      do {
        let response = try await perform(data)
        return try BridgeServiceIPCCodec.decodeResponse(
          Response.self, data: response, requestID: requestID)
      } catch BridgeServiceIPCCodecError.remoteError(let failure)
        where failure.code == "busy" && failure.retryable && attempt < 2
      {
        attempt += 1
        try await Task.sleep(for: .milliseconds(250 * attempt))
      }
    }
  }

  private func acquireModelRead() async throws {
    try Task.checkCancellation()
    guard !invalidated else { throw BridgeServiceClientError.unavailable }
    // Model processes can stay alive across several startup queries. Leave
    // the service's remaining request slots available for tasks and controls.
    if activeModelReads < 3 {
      activeModelReads += 1
      return
    }
    let id = UUID()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        pendingModelReads.append(ModelReadWaiter(id: id, continuation: continuation))
      }
    } onCancel: {
      Task { await self.cancelPendingModelRead(id) }
    }
  }

  private func releaseModelRead() {
    if pendingModelReads.isEmpty {
      activeModelReads -= 1
    } else {
      pendingModelReads.removeFirst().continuation.resume()
    }
  }

  private func cancelPendingModelRead(_ id: UUID) {
    guard let index = pendingModelReads.firstIndex(where: { $0.id == id }) else { return }
    pendingModelReads.remove(at: index).continuation.resume(throwing: CancellationError())
  }

  func failPendingModelReads() {
    let pending = pendingModelReads
    pendingModelReads.removeAll()
    for waiter in pending {
      waiter.continuation.resume(throwing: BridgeServiceClientError.unavailable)
    }
  }
}
