import BridgeAgentCore
import BridgeServiceCore
import Foundation

extension ServiceAgentAutoDiscovery {
  static func qoderExecutablePath(_ path: String, distribution: QoderDistribution) throws -> String
  {
    guard let canonical = canonicalRegularFile(path) else {
      throw ServiceStoreError.invalidArgument("qoder.executable_path")
    }
    let entry = URL(fileURLWithPath: canonical)
    let suffix = entry.pathExtension.lowercased()
    let wrapper =
      ["cmd", "bat"].contains(suffix)
      || entry.lastPathComponent.lowercased().contains("npm-dispatcher")
    guard wrapper else { return canonical }
    let package = distribution == .cn ? "@qodercn-ai/qoderclicn" : "@qoder-ai/qodercli"
    let command = distribution == .cn ? "qoderclicn" : "qodercli"
    var directory = entry.deletingLastPathComponent()
    for _ in 0..<8 {
      for root in qoderPackageRoots(near: directory, package: package) {
        if let resolved = try officialQoderEntry(root: root, package: package, command: command) {
          return resolved
        }
      }
      let parent = directory.deletingLastPathComponent()
      if parent.path == directory.path { break }
      directory = parent
    }
    throw ServiceStoreError.invalidArgument("qoder.official_cli_entry_missing")
  }

  private static func qoderPackageRoots(near directory: URL, package: String) -> [URL] {
    var roots = [
      directory, directory.appendingPathComponent("node_modules/" + package),
      directory.appendingPathComponent("Data/global/node_modules/" + package),
      directory.appendingPathComponent("global/node_modules/" + package),
    ]
    let global = directory.appendingPathComponent("global")
    let versions =
      (try? FileManager.default.contentsOfDirectory(
        at: global, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]))
      ?? []
    for version in versions.sorted(by: { $0.lastPathComponent > $1.lastPathComponent }).prefix(16)
    where version.lastPathComponent.allSatisfy(\.isNumber) {
      roots.append(version.appendingPathComponent("node_modules/" + package))
    }
    return roots
  }

  private static func officialQoderEntry(root: URL, package: String, command: String) throws
    -> String?
  {
    let manifest = root.appendingPathComponent("package.json")
    guard canonicalRegularFile(manifest.path) != nil else { return nil }
    let handle = try FileHandle(forReadingFrom: manifest)
    defer { try? handle.close() }
    guard let bytes = try handle.read(upToCount: 131073), bytes.count <= 131072,
      let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
      object["name"] as? String == package,
      let bin = object["bin"] as? [String: String], let relative = bin[command],
      !relative.isEmpty, !relative.contains("\0"), !AgentPathSemantics.isAbsolute(relative)
    else { return nil }
    let packageRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
    guard let executable = canonicalRegularFile(root.appendingPathComponent(relative).path),
      AgentPathSemantics.isContained(executable, in: packageRoot),
      ["js", "mjs", "cjs"].contains(URL(fileURLWithPath: executable).pathExtension.lowercased())
    else { throw ServiceStoreError.invalidArgument("qoder.official_cli_entry_invalid") }
    return executable
  }
}
