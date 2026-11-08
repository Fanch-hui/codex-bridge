import Foundation

extension PiRPCExecution {
  /// Starts write admission for a tool call of the Bridge extension. The extension only sends
  /// these requests when the task carries a gate, so a request without one is a protocol error.
  func admitWriteGate(_ gateRequest: PiToolWriteGateRequest) async throws {
    guard let writeGate else { throw PiRPCError.invalidRecord }
    guard phase == .active else {
      try await client.answerUI(id: gateRequest.wireID, fields: ["cancelled": .bool(true)])
      return
    }
    try await writeGate.admit(gateRequest)
  }
}
