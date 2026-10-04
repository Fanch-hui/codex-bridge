import BridgeAgentCore
import Foundation

extension ServiceAgentSetupInstaller {
  func installNode(in directory: URL) async throws -> String {
    let bytes = try await io.fetch(URL(string: "https://nodejs.org/dist/index.json")!)
    guard let releases = try JSONSerialization.jsonObject(with: bytes) as? [[String: Any]],
      let release = releases.first(where: {
        ($0["lts"] as? String) != nil
          && Self.nodeVersionSupported($0["version"] as? String ?? "")
      }), let version = release["version"] as? String
    else { throw ServiceAgentSetupInstallError.invalidMetadata("Node LTS") }
    let stem = "node-\(version)-\(platform.nodeArchivePlatform)-\(platform.architecture)"
    let filename = stem + (platform.os == "windows" ? ".zip" : ".tar.gz")
    let base = "https://nodejs.org/dist/\(version)"
    let checksums = try await io.fetch(URL(string: base + "/SHASUMS256.txt")!)
    guard
      let checksum = String(decoding: checksums, as: UTF8.self)
        .split(whereSeparator: \.isNewline).compactMap({ line -> String? in
          let pieces = line.split(whereSeparator: \.isWhitespace)
          return pieces.count == 2 && pieces[1] == filename ? String(pieces[0]) : nil
        }).first
    else { throw ServiceAgentSetupInstallError.invalidMetadata("Node checksum") }
    let archive = directory.appendingPathComponent(filename)
    defer { try? FileManager.default.removeItem(at: archive) }
    try await io.download(URL(string: base + "/" + filename)!, to: archive)
    try ServiceAgentSetupInstallIntegrity.verify(archive, digest: checksum, algorithm: "sha256")
    // Keep npm's own modules separate from the Agent prefix so npm cannot prune itself on Windows.
    let nodeRoot = directory.appendingPathComponent("node-runtime")
    try FileManager.default.createDirectory(at: nodeRoot, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: nodeRoot.appendingPathComponent(".scratch")) }
    try await extract(archive, into: nodeRoot)
    let extracted = nodeRoot.appendingPathComponent(stem)
    for item in try FileManager.default.contentsOfDirectory(
      at: extracted, includingPropertiesForKeys: nil)
    {
      try FileManager.default.moveItem(
        at: item, to: nodeRoot.appendingPathComponent(item.lastPathComponent))
    }
    try FileManager.default.removeItem(at: extracted)
    let node = try executable(
      nodeRoot.appendingPathComponent(platform.os == "windows" ? "node.exe" : "bin/node"))
    let bin = directory.appendingPathComponent("bin")
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: false)
    let nearbyNode = bin.appendingPathComponent("node" + platform.executableSuffix)
    if platform.os == "windows" {
      do {
        try FileManager.default.linkItem(at: URL(fileURLWithPath: node), to: nearbyNode)
      } catch {
        try FileManager.default.copyItem(at: URL(fileURLWithPath: node), to: nearbyNode)
      }
    } else {
      try FileManager.default.createSymbolicLink(
        atPath: nearbyNode.path, withDestinationPath: "../node-runtime/bin/node")
    }
    let output = try await io.run(
      [node, "--version"], cwd: directory,
      environment: installEnvironment(in: directory, node: node))
    guard Self.nodeVersionSupported(output.trimmingCharacters(in: .whitespacesAndNewlines)) else {
      throw ServiceAgentSetupInstallError.commandFailed("Node 版本要求至少 22.19.0")
    }
    return node
  }

  static func nodeVersionSupported(_ version: String) -> Bool {
    let components = version.trimmingCharacters(in: CharacterSet(charactersIn: "v \r\n"))
      .split(separator: ".").compactMap { Int($0) }
    guard components.count == 3 else { return false }
    return components[0] >= 24
      || (components[0] == 22 && !components.lexicographicallyPrecedes([22, 19, 0]))
  }

  func reusableNode(near executable: String, cwd: URL) async -> String? {
    guard
      let candidate = AgentNodeExecutableResolver.resolve(
        near: executable, environment: sourceEnvironment),
      let output = try? await io.run(
        [candidate, "--version"], cwd: cwd,
        environment: installEnvironment(in: cwd, node: candidate)),
      Self.nodeVersionSupported(output.trimmingCharacters(in: .whitespacesAndNewlines))
    else { return nil }
    return candidate
  }
}
