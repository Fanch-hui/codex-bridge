import BridgeACP
import Foundation

enum ProviderStreamItem: Sendable {
  case event(ProviderResponseEvent, credit: Int)
  case completed(Result<ACPJSONValue, any Error>)
}

struct ProviderStreamDelivery: Sendable {
  let continuation: AsyncStream<ProviderStreamItem>.Continuation
  let task: Task<Void, Never>

  func enqueue(_ item: ProviderStreamItem) throws {
    switch continuation.yield(item) {
    case .enqueued: break
    case .terminated: break
    case .dropped: throw ProviderRuntimeError.invalidMessage
    @unknown default: throw ProviderRuntimeError.invalidMessage
    }
  }
}

extension ProviderHostClient {
  func makeDelivery(id: Int64, handler: @escaping StreamHandler) -> ProviderStreamDelivery {
    // A 512 KiB host window permits at most 256 frames with its 2 KiB per-frame charge.
    let events = AsyncStream.makeStream(
      of: ProviderStreamItem.self, bufferingPolicy: .bufferingOldest(258))
    let task = Task { [weak self] in
      do {
        for await item in events.stream {
          try Task.checkCancellation()
          switch item {
          case .event(let event, let credit):
            try await handler(event)
            try await self?.returnCredit(id, count: credit)
          case .completed(let result):
            await self?.finish(id, result: result)
            return
          }
        }
      } catch {
        await self?.cancel(id, error: error)
      }
    }
    return ProviderStreamDelivery(continuation: events.continuation, task: task)
  }

  func complete(_ id: Int64, item: Pending, result: Result<ACPJSONValue, any Error>) throws {
    if let delivery = item.delivery {
      try delivery.enqueue(.completed(result))
    } else {
      finish(id, result: result)
    }
  }

  private func returnCredit(_ id: Int64, count: Int) async throws {
    guard count > 0, !closed, pending[id]?.cancelling == false else { return }
    try await send(
      .object([
        "method": .string("credit"),
        "params": .object(["id": .integer(id), "n": .integer(Int64(count))]),
      ]))
  }
}
