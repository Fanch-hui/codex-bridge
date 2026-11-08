import BridgeSecurity
import Foundation

struct ClaudeHostRuntimeResources {
  let entry: SecureFileArtifactSnapshot
  let lock: SecureFileArtifactSnapshot
  let vendor: SecureFileArtifactSnapshot
}

enum ClaudeRuntimeResources {
  static func load(directory: String?) throws -> ClaudeHostRuntimeResources {
    let root: URL
    if let directory {
      root = URL(fileURLWithPath: directory, isDirectory: true)
    } else if let url = Bundle.module.resourceURL {
      root = url.appendingPathComponent("ClaudeHost")
    } else {
      throw SecureFileArtifactError.invalidPath
    }
    var files: [String: SecureFileArtifactSnapshot] = [:]
    for (name, expected) in hashes {
      let maximum: UInt64 = name == "vendor.mjs" ? 4 * 1_024 * 1_024 : 1_024 * 1_024
      let snapshot = try SecureFileArtifactSnapshot.capture(
        at: root.appendingPathComponent(name).path, maximumBytes: maximum)
      guard snapshot.sha256 == expected else { throw SecureFileArtifactError.changed }
      files[name] = snapshot
    }
    guard let entry = files["index.mjs"], let lock = files["package-lock.json"],
      let vendor = files["vendor.mjs"]
    else { throw SecureFileArtifactError.invalidPath }
    return ClaudeHostRuntimeResources(entry: entry, lock: lock, vendor: vendor)
  }

  static let hashes: [String: String] = [
    "CLAUDE-SDK-LICENSE.txt": "8ce94b9478bb9868f9641f818e06cd722fbe55d4c22e2d2ed11971b20146173a",
    "configuration.mjs": "7ffe8e6801e8fb919aa6b531e856085e069450757373cc5dfba136fcd1c74957",
    "events.mjs": "fcf42010025ef14e3c986f82c39254e1bcb92113183b423c07c01a14d10f8747",
    "index.mjs": "b4782c2f5e35167a1aff02a25a65302223f43a4387ed56957bd83cb8b1b70cf8",
    "input.mjs": "04a19989345ba2b9725bec1766c97ac09c8656f41f839920d98eeaea36194ff5",
    "package-lock.json": "aa7fd03a893a4b4aa7679cd210bffca5892ad24307ae0d3465f29a287f4d8102",
    "package.json": "d207ac629c51388d3b471607a4c49c50c7f66149bce211f5ca880c09619c2f4d",
    "policy.mjs": "c9676559fff67ee9c5ac2d40e0b1995190b5ee7116d72351acde7d89ce53f06d",
    "process.mjs": "a5b47adfe23b5d689d9034d1edbae4040d24f85583e90795c0e8cfbdeedfe874",
    "rpc.mjs": "c7e300b1220464f8560d5a690414a8fa313e5abe985ad2d7324aa413bc131c4b",
    "sdk.mjs": "b99b1fb2bc7a31f4ae26d0b684808d3be809dbc6111e84a9966adf9125aa9aec",
    "session.mjs": "9f5f0c2fe63ac5eea4d8b140b0c92c5acb1eb0ac3a74412a58981255a6c662fb",
    "validation.mjs": "6af1c980e8cba981bc457cdd073ac314ee2c3b8e79af61623b55c9b275261963",
    "vendor.mjs": "201cffa3641e0d3f43b0c8e51af224a80c29a1eb880e23e776602160c7a1eaf9",
    "workspace-files.mjs": "735a6929b02ab926b8c0f0f4e75d507d5120c64e54052a82558dd22f3328baba",
    "write-admission.mjs": "6e26d7e0575a7461cab9c0ee43c5b4b6189ba53ac63d4a165927eec96690d0c7",
  ]
}
