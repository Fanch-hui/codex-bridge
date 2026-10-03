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
    "account-scope.mjs": "61beef4f429441d00b1209f2c6892638f8690d13a43f31901760bbab312bc298",
    "configuration.mjs": "2162d4bcf032e442f36d9544d5154bd1a6592e22ec1c0e24f39082e63caa0685",
    "process.mjs": "96d78d8db77b527689da9fefd2917ebfbdf99b3a4acd87c4108e8fc5ea5b145c",
    "native-history.mjs": "390e08ce53c6c5a299729d4aca4afc99e1cb45cad79f51059a86c29ce6e34f7b",
    "events.mjs": "e5ea692c35123b670f12b1954c223c72470e2640f3ea280e9c2c177fde23fe71",
    "index.mjs": "273b1e479951eaa1e306af5c38f23e9f6c2bfdf5409d6728f6df6402d4cf6dd3",
    "input.mjs": "1ee8b9841d3c17b3175d5dfb0525a135ff3fc49e61680b9619d47af169c3f268",
    "models.mjs": "44442327ff6a9d555993b0d6645abfb4aae97876b380884f7c9a7af7395cf877",
    "policy.mjs": "68e5c786b61d8774a92cdf9041c207152d5220496824a84f67a01340a66ed8ba",
    "rpc.mjs": "3de8b0274634185bf88789fe5670afca5a1d9d01c7c8e7617697a48fe4a9292b",
    "sdk.mjs": "0bb18e5aca146bf1b93a9d3aee2bd7e5fdf60946fec9a0a8daf9b5214d715b87",
    "session.mjs": "359024ac46d2f2af95ef29a6586b30be00bbd7dec1f0cd6681444beeb9b3b6bc",
    "skill-resources.mjs": "bc72e4bb849050ff2093d054c910b75c4097c06631aad44ddd70824b4e14524c",
    "usage.mjs": "ccb9b84eea18c2721793e8770627b3a501ab834ddf89a565184a6f6a66ff65e3",
    "validation.mjs": "465c2f02388d346513e29abec1afdf885a33f43d93370f3883d30e7a45823994",
  ]
}
