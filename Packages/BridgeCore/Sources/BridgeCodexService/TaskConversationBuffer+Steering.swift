import BridgeDomain
import Foundation

extension TaskConversationBuffer {
  func presentImmediateSteer(taskID: TaskID, content: String) async -> UUID {
    let id = UUID()
    state(taskID: taskID).pendingImmediateSteers.append(
      (id, content.trimmingCharacters(in: .whitespacesAndNewlines)))
    await appendUserMessage(taskID: taskID, content: content)
    return id
  }

  func discardImmediateSteerReceipt(taskID: TaskID, id: UUID) {
    states[taskID]?.pendingImmediateSteers.removeAll { $0.id == id }
  }

  func recordDispatchedSteer(taskID: TaskID, content: String) async {
    let state = state(taskID: taskID)
    let normalized = content.trimmingCharacters(in: .whitespacesAndNewlines)
    if let index = state.pendingImmediateSteers.firstIndex(where: { $0.content == normalized }) {
      state.pendingImmediateSteers.remove(at: index)
      return
    }
    await appendUserMessage(taskID: taskID, content: content)
  }
}
