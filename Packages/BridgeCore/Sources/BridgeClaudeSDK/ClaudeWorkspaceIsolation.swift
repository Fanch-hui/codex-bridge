import BridgeACP
import BridgeAgentCore
import BridgeProcess
import BridgeSecurity
import Foundation

enum ClaudeWorkspaceIsolation {
  static func prepare(
    _ launch: ACPProcessTransportConfiguration, runtimeDirectory: String,
    cliArtifact: SecureFileArtifactSnapshot, nodeArtifact: SecureFileArtifactSnapshot
  ) throws -> ACPProcessTransportConfiguration {
    guard let executable = launch.argv.first, executable == nodeArtifact.canonicalPath else {
      throw AgentRuntimeError.invalidRequest("claude.executable")
    }
    let isolated = try WorkspaceProcessIsolation.prepare(
      executableURL: URL(fileURLWithPath: cliArtifact.canonicalPath), arguments: [],
      environment: launch.environment, workspaceRoot: URL(fileURLWithPath: launch.workingDirectory),
      runtimeDirectory: URL(fileURLWithPath: runtimeDirectory), denyProcessFork: true)
    guard let home = isolated.environment["HOME"],
      let sourceHome = launch.environment["HOME"]
    else { throw AgentRuntimeError.invalidRequest("claude.home") }
    let config = URL(fileURLWithPath: home, isDirectory: true)
      .appendingPathComponent(".claude", isDirectory: true)
    try prepareConfigDirectory(config)
    let source =
      launch.environment["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : $0 }
      ?? URL(fileURLWithPath: sourceHome, isDirectory: true)
      .appendingPathComponent(".claude", isDirectory: true).path
    guard AgentPathSemantics.isAbsolute(source), !source.contains("\0") else {
      throw AgentRuntimeError.invalidRequest("claude.config_directory")
    }
    try linkCredentialFile(
      source: URL(fileURLWithPath: source, isDirectory: true), destination: config,
      protectedRoots: [isolated.currentDirectoryURL, URL(fileURLWithPath: runtimeDirectory)])
    var environment = isolated.environment
    environment["CLAUDE_CONFIG_DIR"] = config.path
    environment["CODEX_BRIDGE_CLAUDE_ISOLATED"] = "1"
    environment["CODEX_BRIDGE_CLAUDE_ISOLATION_PROFILE"] = isolated.arguments[1]
    environment["CODEX_BRIDGE_CLAUDE_WORKSPACE"] = isolated.currentDirectoryURL.path
    environment["CODEX_BRIDGE_CLAUDE_CLI_ARTIFACT"] = try encodedIdentity(cliArtifact)
    environment["CODEX_BRIDGE_CLAUDE_NODE_ARTIFACT"] = try encodedIdentity(nodeArtifact)
    return ACPProcessTransportConfiguration(
      argv: launch.argv,
      workingDirectory: isolated.currentDirectoryURL.path,
      environment: environment,
      maximumFrameBytes: launch.maximumFrameBytes,
      maximumStandardErrorBytes: launch.maximumStandardErrorBytes,
      maximumLifetime: launch.maximumLifetime,
      inputEOFGracePeriod: launch.inputEOFGracePeriod,
      processGroupName: launch.processGroupName)
  }

  private static func encodedIdentity(_ artifact: SecureFileArtifactSnapshot) throws -> String {
    let values = [
      "path": artifact.canonicalPath, "device": String(artifact.device),
      "inode": String(artifact.inode), "size": String(artifact.fileSize),
      "mtimeNs": String(artifact.modificationTimeNanoseconds),
    ]
    return String(decoding: try JSONEncoder().encode(values), as: UTF8.self)
  }

  private static func prepareConfigDirectory(_ directory: URL) throws {
    let manager = FileManager.default
    if !manager.fileExists(atPath: directory.path) {
      try manager.createDirectory(
        at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }
    let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    guard values.isDirectory == true, values.isSymbolicLink != true else {
      throw AgentRuntimeError.invalidRequest("claude.config_directory")
    }
  }

  private static func linkCredentialFile(source: URL, destination: URL, protectedRoots: [URL])
    throws
  {
    let manager = FileManager.default
    let input = source.appendingPathComponent(".credentials.json")
    guard manager.fileExists(atPath: input.path) else { return }
    let resolved = input.resolvingSymlinksInPath().standardizedFileURL
    let roots = protectedRoots.map { $0.resolvingSymlinksInPath().standardizedFileURL.path }
    guard roots.allSatisfy({ !contains($0, resolved.path) }) else {
      throw AgentRuntimeError.invalidRequest("claude.config_directory")
    }
    let link = destination.appendingPathComponent(".credentials.json")
    if let existing = try? manager.destinationOfSymbolicLink(atPath: link.path) {
      guard existing == resolved.path else {
        throw AgentRuntimeError.invalidRequest("claude.config_directory")
      }
      return
    }
    guard !manager.fileExists(atPath: link.path) else {
      throw AgentRuntimeError.invalidRequest("claude.config_directory")
    }
    try manager.createSymbolicLink(atPath: link.path, withDestinationPath: resolved.path)
  }

  private static func contains(_ root: String, _ path: String) -> Bool {
    let root = root.precomposedStringWithCanonicalMapping.lowercased()
    let path = path.precomposedStringWithCanonicalMapping.lowercased()
    return path == root || path.hasPrefix(root == "/" ? "/" : root + "/")
  }
}
