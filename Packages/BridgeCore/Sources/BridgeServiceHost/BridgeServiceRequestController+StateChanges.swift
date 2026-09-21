import BridgeIPC
import Foundation

extension BridgeServiceRequestController {
  func startStateChanges() async {
    guard let streamSink else { return }
    await conversationStreamGate.acquire()
    defer { conversationStreamGate.release() }
    guard !streamingStopped, stateChangeForwarder == nil else { return }
    let tasks = await composition.tasks.changes.subscribe()
    let approvals = await composition.application.approvals.changes.subscribe()
    stateChangeForwarder = Task {
      await withTaskGroup(of: Void.self) { group in
        for stream in [tasks, approvals] {
          group.addTask {
            for await _ in stream {
              guard !Task.isCancelled,
                let payload = try? JSONEncoder().encode(IPCServiceStateChanged())
              else { return }
              streamSink.push(payload)
            }
          }
        }
      }
    }
  }
}
