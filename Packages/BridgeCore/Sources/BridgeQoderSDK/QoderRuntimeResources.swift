import BridgeSecurity
import Foundation

struct QoderHostRuntimeResources {
  let entry: SecureFileArtifactSnapshot
}

enum QoderRuntimeResources {
  static func load(directory: String?) throws -> QoderHostRuntimeResources {
    let root: URL
    if let directory {
      root = URL(fileURLWithPath: directory, isDirectory: true)
    } else if let url = Bundle.module.resourceURL {
      root = url.appendingPathComponent("QoderHost")
    } else {
      throw SecureFileArtifactError.invalidPath
    }
    var entry: SecureFileArtifactSnapshot?
    for (name, expected) in hashes {
      let snapshot = try SecureFileArtifactSnapshot.capture(
        at: root.appendingPathComponent(name).path, maximumBytes: 262144)
      guard snapshot.sha256 == expected else { throw SecureFileArtifactError.changed }
      if name == "index.mjs" { entry = snapshot }
    }
    guard let entry else { throw SecureFileArtifactError.invalidPath }
    return QoderHostRuntimeResources(entry: entry)
  }

  static let hashes: [String: String] = [
    "account-scope.mjs": "1dc5734ba341fb95b6eace2c55522fa22dfdbf0501121a0614904bdecca746e3",
    "configuration.mjs": "2162d4bcf032e442f36d9544d5154bd1a6592e22ec1c0e24f39082e63caa0685",
    "process.mjs": "96d78d8db77b527689da9fefd2917ebfbdf99b3a4acd87c4108e8fc5ea5b145c",
    "native-history.mjs": "390e08ce53c6c5a299729d4aca4afc99e1cb45cad79f51059a86c29ce6e34f7b",
    "events.mjs": "537ceadd7db1f4914d51d987f910068a498e19fa839f50f266ec83a2817be0d2",
    "index.mjs": "273b1e479951eaa1e306af5c38f23e9f6c2bfdf5409d6728f6df6402d4cf6dd3",
    "input.mjs": "1ee8b9841d3c17b3175d5dfb0525a135ff3fc49e61680b9619d47af169c3f268",
    "models.mjs": "44442327ff6a9d555993b0d6645abfb4aae97876b380884f7c9a7af7395cf877",
    "policy.mjs": "71086a874e8639a51b21f95b0b7f5d494ef4cd54545119d5b8df7d56548a843a",
    "rpc.mjs": "3de8b0274634185bf88789fe5670afca5a1d9d01c7c8e7617697a48fe4a9292b",
    "sdk.mjs": "f08f5c96b53d0bab6b8ff0a363c5b17565baff3dd7269625efaf7bf82a203fd0",
    "session.mjs": "1b471104181da4fc1577a931ad3b063e8fd48246f86f32c2a9724c7bb555eb4d",
    "skill-resources.mjs": "bc72e4bb849050ff2093d054c910b75c4097c06631aad44ddd70824b4e14524c",
    "usage.mjs": "ccb9b84eea18c2721793e8770627b3a501ab834ddf89a565184a6f6a66ff65e3",
    "validation.mjs": "5a058e471b5038683c7ac3b94dac5a09e2072f3271b9a74e5ecc841e650cedc3",
  ]
}
