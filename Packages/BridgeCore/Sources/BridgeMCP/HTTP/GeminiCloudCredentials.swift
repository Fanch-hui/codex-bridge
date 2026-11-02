import Crypto
import Foundation

public enum GeminiCloudCredentials {
  public static func accessKey(for credential: String) -> String {
    derive("codex-bridge:gemini-cloud:mcp:v1\0", credential: credential)
  }

  public static func relayKey(for credential: String) -> String {
    derive("codex-bridge:gemini-cloud:relay:v1\0", credential: credential)
  }

  private static func derive(_ prefix: String, credential: String) -> String {
    SHA256.hash(data: Data((prefix + credential).utf8))
      .map { String(format: "%02x", $0) }.joined()
  }
}

public final class GeminiCloudAccessGate: @unchecked Sendable {
  private let lock = NSLock()
  private var enabled: Bool
  private var generation: UInt64 = 0

  public init(enabled: Bool = false) {
    self.enabled = enabled
  }

  public func setEnabled(_ enabled: Bool) {
    lock.withLock {
      self.enabled = enabled
      generation &+= 1
    }
  }

  public var isEnabled: Bool {
    lock.withLock { enabled }
  }

  package var currentGeneration: UInt64? {
    lock.withLock { enabled ? generation : nil }
  }

  package func isCurrent(_ generation: UInt64) -> Bool {
    lock.withLock { enabled && self.generation == generation }
  }
}
