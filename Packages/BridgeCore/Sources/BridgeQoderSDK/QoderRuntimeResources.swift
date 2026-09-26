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
    "configuration.mjs": "4a67934aa65bb66a3774b3ba496290f61695df06c182daff114914a8130d39d6",
    "process.mjs": "96d78d8db77b527689da9fefd2917ebfbdf99b3a4acd87c4108e8fc5ea5b145c",
    "native-history.mjs": "390e08ce53c6c5a299729d4aca4afc99e1cb45cad79f51059a86c29ce6e34f7b",
    "events.mjs": "e5ea692c35123b670f12b1954c223c72470e2640f3ea280e9c2c177fde23fe71",
    "index.mjs": "48ee8808b9561b4c9da16b817a554f2dc94c88433e3e6d08bcad0f6196f93975",
    "input.mjs": "1ee8b9841d3c17b3175d5dfb0525a135ff3fc49e61680b9619d47af169c3f268",
    "models.mjs": "44442327ff6a9d555993b0d6645abfb4aae97876b380884f7c9a7af7395cf877",
    "policy.mjs": "cfc14f78a006779847b8042fcfa7fd1ee47c70ff7db979bd60214f5ae821dd53",
    "rpc.mjs": "edc8970df12829fe809d1d2eb889c9ef769ce540f62f7ec44ddfec476108cc1f",
    "sdk.mjs": "ee4e83c6356757021eaa521c01bfbf265f9f42c8838f9f1c1f0e984a022d9bdd",
    "session.mjs": "5088dfd8834d1d3913c492b8806e8ec240d99824a6501ae1644fdb9592cdbcb2",
    "skill-resources.mjs": "bc72e4bb849050ff2093d054c910b75c4097c06631aad44ddd70824b4e14524c",
    "usage.mjs": "ccb9b84eea18c2721793e8770627b3a501ab834ddf89a565184a6f6a66ff65e3",
    "validation.mjs": "465c2f02388d346513e29abec1afdf885a33f43d93370f3883d30e7a45823994",
  ]
}
