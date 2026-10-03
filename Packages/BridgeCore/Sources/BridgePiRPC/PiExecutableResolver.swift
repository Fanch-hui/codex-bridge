import BridgeAgentCore
import BridgeSecurity
import Foundation

struct PiExecutableResolution {
  let executableArgv: [String]
  let entry: SecureFileArtifactSnapshot
  let manifest: SecureFileArtifactSnapshot?

  var artifacts: [AgentInstallationArtifact] {
    var values = [Self.artifact(entry, role: .runtimeManifest)]
    if let manifest { values.append(Self.artifact(manifest, role: .dependencyLock)) }
    return values
  }

  private static func artifact(
    _ value: SecureFileArtifactSnapshot,
    role: AgentInstallationArtifactRole
  ) -> AgentInstallationArtifact {
    AgentInstallationArtifact(
      role: role, canonicalPath: value.canonicalPath,
      device: value.device, inode: value.inode, fileSize: value.fileSize,
      modificationTimeNanoseconds: value.modificationTimeNanoseconds, sha256: value.sha256)
  }
}

enum PiExecutableResolver {
  private static let packageNames = [
    "@earendil-works/pi-coding-agent", "@mariozechner/pi-coding-agent",
  ]

  static func resolve(executable: SecureFileArtifactSnapshot, node: SecureFileArtifactSnapshot)
    throws -> PiExecutableResolution
  {
    if let package = try package(for: executable.canonicalPath) {
      let entryPath = try binEntry(in: package)
      let entry = try SecureFileArtifactSnapshot.capture(at: entryPath)
      return PiExecutableResolution(
        executableArgv: [node.canonicalPath, entry.canonicalPath],
        entry: entry,
        manifest: package.manifest
      )
    }
    let suffix = URL(fileURLWithPath: executable.canonicalPath).pathExtension.lowercased()
    if ["js", "mjs", "cjs"].contains(suffix) {
      return PiExecutableResolution(
        executableArgv: [node.canonicalPath, executable.canonicalPath],
        entry: executable,
        manifest: nil
      )
    }
    guard suffix != "cmd", suffix != "bat" else {
      throw PiRPCError.invalidArgument("pi_package_manifest_missing")
    }
    return PiExecutableResolution(
      executableArgv: [executable.canonicalPath], entry: executable, manifest: nil)
  }

  private static func package(for executablePath: String) throws -> Package? {
    let locations = candidateManifestLocations(for: executablePath)
    for (root, manifestPath) in locations {
      guard
        let manifest = try? SecureFileArtifactSnapshot.capture(
          at: manifestPath, maximumBytes: 128 * 1_024),
        let data = try? readManifest(manifestPath), data.count <= 128 * 1_024,
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let name = object["name"] as? String, packageNames.contains(name)
      else { continue }
      guard
        (try? SecureFileArtifactSnapshot.capture(
          at: manifestPath, maximumBytes: 128 * 1_024)) == manifest
      else { continue }
      return Package(root: root, manifest: manifest, object: object)
    }
    return nil
  }

  private static func readManifest(_ path: String) throws -> Data {
    let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
    defer { try? handle.close() }
    return try handle.read(upToCount: 128 * 1_024 + 1) ?? Data()
  }

  private static func candidateManifestLocations(for executablePath: String) -> [(URL, String)] {
    var directory = URL(fileURLWithPath: executablePath).deletingLastPathComponent()
      .standardizedFileURL
    var values: [(URL, String)] = []
    for _ in 0..<8 {
      let directManifest = directory.appendingPathComponent("package.json").path
      values.append((directory, directManifest))
      for packageName in packageNames {
        let components = packageName.split(separator: "/").map(String.init)
        let packageRoots = [
          directory.appendingPathComponent("node_modules", isDirectory: true),
          directory.appendingPathComponent("global/5/node_modules", isDirectory: true),
          directory.appendingPathComponent("global/node_modules", isDirectory: true),
          directory.appendingPathComponent("Data/global/node_modules", isDirectory: true),
        ]
        for base in packageRoots {
          var root = base
          for component in components { root.appendPathComponent(component, isDirectory: true) }
          values.append((root, root.appendingPathComponent("package.json").path))
        }
      }
      let parent = directory.deletingLastPathComponent()
      guard parent.path != directory.path else { break }
      directory = parent
    }
    return values
  }

  private static func binEntry(in package: Package) throws -> String {
    let bin = package.object["bin"]
    let relative: String?
    if let path = bin as? String {
      relative = path
    } else {
      relative = (bin as? [String: Any])?["pi"] as? String
    }
    guard let relative, !relative.isEmpty, !relative.contains("\0"),
      !AgentPathSemantics.isAbsolute(relative)
    else { throw PiRPCError.invalidArgument("pi_package_bin") }
    let path = URL(fileURLWithPath: package.root.path)
      .appendingPathComponent(relative).standardizedFileURL.path
    guard AgentPathSemantics.isContained(path, in: package.root.path) else {
      throw PiRPCError.invalidArgument("pi_package_bin")
    }
    return path
  }

  private struct Package {
    let root: URL
    let manifest: SecureFileArtifactSnapshot
    let object: [String: Any]
  }
}
