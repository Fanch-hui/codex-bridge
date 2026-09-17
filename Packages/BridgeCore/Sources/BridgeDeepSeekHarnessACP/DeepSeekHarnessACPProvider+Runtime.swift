import BridgeAgentCore
import Crypto
import Foundation

extension DeepSeekHarnessACPProvider {
  func makeRunDirectory(prefix: String) throws -> String {
    guard !prefix.isEmpty,
      prefix.utf8.count <= 64,
      prefix.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") })
    else {
      throw AgentRuntimeError.invalidRequest("runtime.prefix")
    }
    let base = try prepareRuntimeBase()
    let path = try DeepSeekHarnessACPPathSupport.append(
      "\(prefix)-\(UUID().uuidString.lowercased())",
      to: base,
      isDirectory: true
    )
    return try DeepSeekHarnessACPPathSupport.preparePrivateDirectory(
      path,
      field: "runDirectory",
      withIntermediateDirectories: false
    )
  }

  func makeProbeRoot(_ requested: String?) throws -> ProbeRoot {
    if let requested {
      return ProbeRoot(path: requested, owned: false)
    }
    let path = try makeRunDirectory(prefix: "probe-project")
    return ProbeRoot(path: path, owned: true)
  }

  func makePersistentStateDirectory(
    installation: AgentInstallation,
    request: AgentExecutionRequest
  ) throws -> String? {
    guard let configuredBase = configuration.persistentStateBaseDirectory else { return nil }
    let base = try DeepSeekHarnessACPPathSupport.preparePrivateDirectory(
      configuredBase,
      field: "persistentStateBaseDirectory"
    )
    let identity = [
      installation.providerID.rawValue,
      installation.id.rawValue,
      request.projectID.rawValue,
      request.projectRoot,
    ].joined(separator: "\u{0}")
    let digest = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }
      .joined()
    return try DeepSeekHarnessACPPathSupport.preparePrivateDirectory(
      try DeepSeekHarnessACPPathSupport.append(digest, to: base, isDirectory: true),
      field: "persistentStateDirectory"
    )
  }

  func cleanup(runDirectory: String?, probeRoot: ProbeRoot) {
    if let runDirectory {
      DeepSeekHarnessACPLaunchBuilder.removeRunDirectory(runDirectory)
    }
    if probeRoot.owned {
      DeepSeekHarnessACPLaunchBuilder.removeRunDirectory(probeRoot.path)
    }
  }

  private func prepareRuntimeBase() throws -> String {
    try DeepSeekHarnessACPPathSupport.preparePrivateDirectory(
      configuration.runtimeBaseDirectory,
      field: "runtimeBaseDirectory"
    )
  }
}

struct ProbeRoot: Sendable {
  let path: String
  let owned: Bool
}
