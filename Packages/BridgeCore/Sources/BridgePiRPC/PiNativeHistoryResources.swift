import BridgeSecurity
import Foundation

struct PiNativeHistoryResources {
  let script: SecureFileArtifactSnapshot

  static func load() throws -> Self {
    guard let root = Bundle.module.resourceURL?.appendingPathComponent("PiNativeHistory") else {
      throw PiRPCError.invalidArgument("pi_history_resource_missing")
    }
    let script = try SecureFileArtifactSnapshot.capture(
      at: root.appendingPathComponent("native-history.mjs").path, maximumBytes: 128 * 1_024)
    guard script.sha256 == expectedSHA256 else {
      throw PiRPCError.invalidArgument("pi_history_resource_identity")
    }
    return Self(script: script)
  }

  static let expectedSHA256 = "54123917d1d58b4fa5ff523a8f0e13285e2c8b726ebd2a987d7c07e15c851d79"
}
