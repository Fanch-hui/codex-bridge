import BridgeACP
import BridgeEmbeddedDSH
import Foundation

extension ServiceEmbeddedDSHController {
  func receive(_ event: EmbeddedDSHEvent) async {
    if event.type == "plugin.install", let id = event.payload["requestId"]?.stringValue,
      ["completed", "failed", "cancelled", "unknown"].contains(
        event.payload["status"]?.stringValue ?? "")
    {
      await finishPluginMaintenance(id: id)
    }
    if event.type == "workspace.required" {
      do { try await persistWorkspaceRequest(event) } catch {
        let failure = BridgeServiceRequestController.map(error)
        await receive(
          EmbeddedDSHEvent(
            type: "workspace.persistenceFailed",
            payload: .object(["message": .string(failure.message)])))
      }
    }
    eventCursor += 1
    var entry: [String: ACPJSONValue] = [
      "cursor": .integer(Int64(eventCursor)), "type": .string(event.type),
      "payload": event.payload,
    ]
    if let sessionID = event.sessionID {
      entry["sessionID"] = .string(nativeLogicalIDs[sessionID] ?? sessionID)
    }
    if let sequence = event.sequence { entry["seq"] = .integer(sequence) }
    if let surfaceOp = event.surfaceOp { entry["surfaceOp"] = surfaceOp }
    let value = ACPJSONValue.object(entry)
    let count = (try? value.encodedData().count) ?? 0
    events.append((eventCursor, value, count))
    eventBytes += count
    while events.count > 2_048 || eventBytes > 8 * 1_024 * 1_024 {
      eventBytes -= events.removeFirst().bytes
    }
  }

  func readEvents(_ input: ACPJSONValue) async throws -> ACPJSONValue {
    let after = max(0, input["after"]?.intValue ?? 0)
    let timeout = min(25_000, max(0, input["timeoutMs"]?.intValue ?? 20_000))
    let deadline = ContinuousClock.now.advanced(by: .milliseconds(timeout))
    while after == eventCursor, ContinuousClock.now < deadline, !isShuttingDown {
      try await Task.sleep(for: .milliseconds(150))
    }
    try Task.checkCancellation()
    let first = events.first?.cursor ?? eventCursor + 1
    return .object([
      "events": .array(events.filter { $0.cursor > after }.map(\.value)),
      "cursor": .integer(Int64(eventCursor)),
      "reset": .bool(after < first - 1 || after > eventCursor),
    ])
  }
}
