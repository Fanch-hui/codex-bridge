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
    "account-scope.mjs": "a2c27fb5046d1bbd52a3c287d43e77f7db6ad277a84302599a7e35aeba763577",
    "configuration.mjs": "3666b660e4a4895fc17a5b79dc2d41d16faa8fd18ee79035a65689b504f1dfa6",
    "process.mjs": "96d78d8db77b527689da9fefd2917ebfbdf99b3a4acd87c4108e8fc5ea5b145c",
    "native-history.mjs": "dd76799e95c9b2731980d7582c406efcaacfde36822cb998cc2e9998f4779342",
    "events.mjs": "537ceadd7db1f4914d51d987f910068a498e19fa839f50f266ec83a2817be0d2",
    "index.mjs": "5d4b7ce66afb3821661e48fe5c8f63955d6d0033676fc609671756bed241a31b",
    "input.mjs": "04a19989345ba2b9725bec1766c97ac09c8656f41f839920d98eeaea36194ff5",
    "models.mjs": "44442327ff6a9d555993b0d6645abfb4aae97876b380884f7c9a7af7395cf877",
    "policy.mjs": "d84967a80c006f1fb945a90b8603634f39ec3d72c9fe280eddeeb57f57f28599",
    "rpc.mjs": "c06d84d9262eaa5f45896b4d97ae327853211a807cc90d998366f16a5f50084e",
    "sdk.mjs": "ba11d283ba44c89ee99a275ac10b83fa2c02ba13da22b739caa74cd0ece7146e",
    "session.mjs": "ba6564a025bfc253ba1de192da69e47db48d8c1c388564d1088c86ecff7c2e7d",
    "skill-resources.mjs": "bc72e4bb849050ff2093d054c910b75c4097c06631aad44ddd70824b4e14524c",
    "usage.mjs": "ccb9b84eea18c2721793e8770627b3a501ab834ddf89a565184a6f6a66ff65e3",
    "validation.mjs": "1f93c8d0f5b22c0d735466143adfe4a132edf28e847768c0c85f5ed736d709ec",
    "write-admission.mjs": "454539d3dca1bba3ecc1d46cda5a8254c6d75d5feff2f99d524e41608c5686c0",
  ]
}
