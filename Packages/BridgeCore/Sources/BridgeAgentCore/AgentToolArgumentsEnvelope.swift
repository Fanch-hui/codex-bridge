import Foundation

/// Persists child-run metadata alongside tool arguments without changing the
/// existing ServiceCore message schema. The original redacted arguments stay
/// intact as a string and can be restored for the normal tool details view.
public enum AgentToolArgumentsEnvelope {
  public static let version = 1
  private static let maximumUTF8Bytes = 64 * 1_024

  public struct Decoded: Equatable, Sendable {
    public let arguments: String?
    public let childRuns: [AgentChildRun]

    public init(arguments: String?, childRuns: [AgentChildRun]) {
      self.arguments = arguments
      self.childRuns = childRuns
    }
  }

  public static func encode(
    arguments: String?,
    childRuns: [AgentChildRun]
  ) -> String? {
    guard !childRuns.isEmpty else { return arguments }
    let payload = Payload(version: version, childRuns: childRuns)
    let envelope = Wire(marker: payload, arguments: arguments)
    guard let data = try? JSONEncoder().encode(envelope),
      data.count <= maximumUTF8Bytes
    else { return arguments }
    return String(data: data, encoding: .utf8) ?? arguments
  }

  public static func decode(_ value: String?) -> Decoded? {
    guard let value, let data = value.data(using: .utf8),
      let wire = try? JSONDecoder().decode(Wire.self, from: data),
      wire.marker.version == version
    else { return nil }
    return Decoded(arguments: wire.arguments, childRuns: wire.marker.childRuns)
  }

  private struct Payload: Codable {
    let version: Int
    let childRuns: [AgentChildRun]
  }

  private struct Wire: Codable {
    let marker: Payload
    let arguments: String?

    private enum CodingKeys: String, CodingKey {
      case marker = "__codex_bridge_tool_metadata"
      case arguments
    }
  }
}
