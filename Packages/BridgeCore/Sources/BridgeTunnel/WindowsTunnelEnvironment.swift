package enum WindowsTunnelEnvironment {
  package static let runtimeKeyVariable = "CODEX_BRIDGE_TUNNEL_API_KEY"
  package static let headerSecretVariable = "CODEX_BRIDGE_TUNNEL_TOKEN"
  package static let inheritedVariableNames = ["SystemRoot", "WINDIR"]

  package static func block(
    parentEnvironment: [String: String],
    runtimePath: String,
    runtimeKey: String,
    headerSecret: String
  ) -> [UInt16] {
    var values: [String: String] = [:]
    for name in parentEnvironment.keys.sorted() {
      guard
        let canonicalName = inheritedVariableNames.first(where: {
          $0.uppercased() == name.uppercased()
        })
      else { continue }
      values[canonicalName] = parentEnvironment[name]
    }
    values["TMP"] = runtimePath
    values["TEMP"] = runtimePath
    values["CODEX_HOME"] = WindowsTunnelPathRules.join(runtimePath, "codex-home")
    values[runtimeKeyVariable] = runtimeKey
    values[headerSecretVariable] = headerSecret
    let entries = values.sorted { $0.key.uppercased() < $1.key.uppercased() }
      .map { "\($0.key)=\($0.value)" }
    return Array((entries.joined(separator: "\0") + "\0\0").utf16)
  }
}
