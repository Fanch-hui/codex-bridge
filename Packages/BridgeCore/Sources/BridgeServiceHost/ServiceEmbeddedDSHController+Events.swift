import BridgeACP
import BridgeEmbeddedDSH
import Foundation

extension ServiceEmbeddedDSHController {
  func receive(_ event: EmbeddedDSHEvent) async {
    if event.type == "workspace.recovery.changed" {
      Task {
        do { try await self.reconcileNativeWorkspaceRecovery() } catch {
          await self.receive(
            EmbeddedDSHEvent(
              sessionID: event.sessionID, type: "workspace.recovery.failed",
              payload: .object(["message": .string("核对工作区占用失败，请重新检查状态。")]))
          )
        }
      }
    }
    if event.type == "workspace.writeAvailable", let rootID = event.sessionID {
      Task { await self.retryPendingWorkspaces(rootID: rootID) }
      return
    }
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
    eventSignal.notify()
  }

  func readEvents(_ input: ACPJSONValue) async throws -> ACPJSONValue {
    let after = max(0, input["after"]?.intValue ?? 0)
    let timeout = min(25_000, max(0, input["timeoutMs"]?.intValue ?? 20_000))
    let deadline = ContinuousClock.now.advanced(by: .milliseconds(timeout))
    let generation = workbenchAvailabilityGeneration
    // Read the signal generation before every condition check: a notification that lands while
    // this task is suspended then makes `wait` return immediately instead of being missed.
    var observed = eventSignal.generation
    while after == eventCursor, ContinuousClock.now < deadline, !isShuttingDown,
      !isChangingWorkbenchEnabled, generation == workbenchAvailabilityGeneration
    {
      await eventSignal.wait(after: observed, until: deadline)
      try Task.checkCancellation()
      observed = eventSignal.generation
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
