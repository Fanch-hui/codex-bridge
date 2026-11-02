import Foundation

public struct MCPClientSuccessfulCall: Equatable, Sendable {
  public let route: String
  public let time: Date
}

/// Tracks only successful tool calls and discards evidence from revoked credentials.
public actor MCPClientCallActivity {
  private struct Evidence: Sendable {
    let time: Date
    let generation: UInt64
    let cloudGeneration: UInt64?
  }

  private let admission: MCPClientAdmissionGate?
  private let cloudGate: GeminiCloudAccessGate?
  private var calls: [MCPClientID: [String: Evidence]] = [:]

  public init(admission: MCPClientAdmissionGate?, cloudGate: GeminiCloudAccessGate?) {
    self.admission = admission
    self.cloudGate = cloudGate
  }

  package func record(
    clientID: MCPClientID, route: String, generation: UInt64, cloudGeneration: UInt64?
  ) {
    let evidence = Evidence(time: Date(), generation: generation, cloudGeneration: cloudGeneration)
    guard ["local", "cloud", "shared"].contains(route),
      valid(evidence, clientID: clientID, route: route)
    else { return }
    calls[clientID, default: [:]][route] = evidence
  }

  public func successes(for clientID: MCPClientID) -> [MCPClientSuccessfulCall] {
    (calls[clientID] ?? [:]).compactMap { route, evidence in
      guard valid(evidence, clientID: clientID, route: route) else { return nil }
      return MCPClientSuccessfulCall(route: route, time: evidence.time)
    }.sorted { $0.route < $1.route }
  }

  private func valid(_ evidence: Evidence, clientID: MCPClientID, route: String) -> Bool {
    guard let admission, admission.isCurrent(generation: evidence.generation, for: clientID)
    else { return false }
    if route == "cloud" {
      guard clientID == .gemini, let cloudGate, let generation = evidence.cloudGeneration
      else { return false }
      return cloudGate.isCurrent(generation)
    }
    return evidence.cloudGeneration == nil
  }
}
