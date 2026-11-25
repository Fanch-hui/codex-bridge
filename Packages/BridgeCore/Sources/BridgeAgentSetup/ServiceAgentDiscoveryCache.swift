import BridgeAgentCore
import Foundation

enum ServiceAgentDiscoveryCache {
  private struct Snapshot: Codable {
    let version: Int
    let providers: [String: ServiceAgentDiscoverySummary]
  }

  static func load(from url: URL) -> [AgentProviderID: ServiceAgentDiscoverySummary]? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    guard let data = try? handle.read(upToCount: 262_145), data.count <= 262_144,
      let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
      snapshot.version == 1
    else { return nil }
    return Dictionary(
      uniqueKeysWithValues: snapshot.providers.map { (AgentProviderID(rawValue: $0.key), $0.value) }
    )
  }

  static func save(_ providers: [AgentProviderID: ServiceAgentDiscoverySummary], to url: URL) throws
  {
    let snapshot = Snapshot(
      version: 1,
      providers: Dictionary(uniqueKeysWithValues: providers.map { ($0.key.rawValue, $0.value) })
    )
    let data = try JSONEncoder().encode(snapshot)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    try data.write(to: url, options: .atomic)
  }
}
