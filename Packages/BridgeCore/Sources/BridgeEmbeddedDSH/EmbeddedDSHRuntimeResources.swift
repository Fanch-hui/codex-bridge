import BridgeAgentCore
import BridgeSecurity
import Crypto
import Foundation

struct EmbeddedDSHRuntimeResources: Sendable {
  let root: URL
  let node: SecureFileArtifactSnapshot
  let entry: SecureFileArtifactSnapshot

  static func load(root: URL) throws -> Self {
    let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL
    let manifestURL = canonicalRoot.appendingPathComponent("runtime.json")
    let before: SecureFileArtifactSnapshot
    let manifest: Manifest
    do {
      before = try SecureFileArtifactSnapshot.capture(
        at: manifestURL.path, maximumBytes: 32 * 1_024 * 1_024)
      guard AgentPathSemantics.isContained(before.canonicalPath, in: canonicalRoot.path) else {
        throw EmbeddedDSHRuntimeError.invalidManifest
      }
      manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
      guard
        before
          == (try SecureFileArtifactSnapshot.capture(
            at: manifestURL.path, maximumBytes: 32 * 1_024 * 1_024))
      else { throw EmbeddedDSHRuntimeError.invalidManifest }
    } catch let error as EmbeddedDSHRuntimeError {
      throw error
    } catch {
      throw EmbeddedDSHRuntimeError.invalidManifest
    }

    guard manifest.protocolVersion == 1,
      manifest.dshVersion == "0.2.2-rc.1",
      manifest.dshCommit == "66491b05e3f05ad35bcdd4f6cd7ed26041d9e3db",
      manifest.platform == EmbeddedDSHRuntimeTarget.platform,
      manifest.architecture == EmbeddedDSHRuntimeTarget.architecture
    else { throw EmbeddedDSHRuntimeError.incompatibleRuntime }

    let validator = try ResourceValidator(root: canonicalRoot, manifest: manifest)
    let snapshots = try validator.validate()
    guard let node = snapshots[validator.key(manifest.node)],
      let entry = snapshots[validator.key(manifest.entry)]
    else { throw EmbeddedDSHRuntimeError.invalidManifest }
    return Self(root: canonicalRoot, node: node, entry: entry)
  }

  func validateEntrypoints() throws {
    do {
      guard
        node
          == (try SecureFileArtifactSnapshot.capture(
            at: node.canonicalPath, requiresExecutable: true)),
        entry == (try SecureFileArtifactSnapshot.capture(at: entry.canonicalPath))
      else { throw EmbeddedDSHRuntimeError.resourceChanged("运行入口") }
    } catch let error as EmbeddedDSHRuntimeError {
      throw error
    } catch {
      throw EmbeddedDSHRuntimeError.resourceChanged("运行入口")
    }
  }
}

private struct Manifest: Decodable, Sendable {
  struct File: Decodable, Sendable {
    let path: String
    let sha256: String
  }
  struct Link: Decodable, Sendable {
    let path: String
    let target: String
  }

  let protocolVersion: Int
  let dshVersion: String
  let dshCommit: String
  let node: String
  let entry: String
  let platform: String
  let architecture: String
  let files: [File]
  let links: [Link]
}

private struct ResourceValidator: Sendable {
  let root: URL
  let manifest: Manifest
  let files: [String: Manifest.File]
  let links: [String: Manifest.Link]

  init(root: URL, manifest: Manifest) throws {
    guard !manifest.files.isEmpty, manifest.files.count + manifest.links.count <= 200_000 else {
      throw EmbeddedDSHRuntimeError.invalidManifest
    }
    self.root = root
    self.manifest = manifest
    var files: [String: Manifest.File] = [:]
    var links: [String: Manifest.Link] = [:]
    for file in manifest.files {
      guard Self.validPath(file.path), Self.validDigest(file.sha256) else {
        throw EmbeddedDSHRuntimeError.invalidManifest
      }
      let key = Self.pathKey(file.path)
      guard files.updateValue(file, forKey: key) == nil else {
        throw EmbeddedDSHRuntimeError.invalidManifest
      }
    }
    for link in manifest.links {
      guard Self.validPath(link.path), !link.target.isEmpty, !link.target.contains("\0"),
        !AgentPathSemantics.isAbsolute(link.target)
      else { throw EmbeddedDSHRuntimeError.invalidManifest }
      let key = Self.pathKey(link.path)
      guard files[key] == nil, links.updateValue(link, forKey: key) == nil else {
        throw EmbeddedDSHRuntimeError.invalidManifest
      }
    }
    guard Self.validPath(manifest.node), Self.validPath(manifest.entry),
      files[Self.pathKey(manifest.node)] != nil, files[Self.pathKey(manifest.entry)] != nil
    else { throw EmbeddedDSHRuntimeError.invalidManifest }
    self.files = files
    self.links = links
  }

  func key(_ path: String) -> String { Self.pathKey(path) }

  func validate() throws -> [String: SecureFileArtifactSnapshot] {
    try validateDirectoryContents()
    for link in links.values { try validateLink(link) }
    let allFiles = Array(files.values)
    let workers = min(4, max(1, ProcessInfo.processInfo.activeProcessorCount), allFiles.count)
    let results = ValidationResults()
    DispatchQueue.concurrentPerform(iterations: workers) { worker in
      do {
        var entrypoints: [String: SecureFileArtifactSnapshot] = [:]
        let start = allFiles.count * worker / workers
        let end = allFiles.count * (worker + 1) / workers
        for index in start..<end {
          let file = allFiles[index]
          let executable = key(file.path) == key(manifest.node)
          let snapshot = try validateFile(file, requiresExecutable: executable)
          if executable || key(file.path) == key(manifest.entry) {
            guard let snapshot else { throw EmbeddedDSHRuntimeError.invalidManifest }
            entrypoints[key(file.path)] = snapshot
          }
        }
        results.append(entrypoints)
      } catch {
        results.fail(error)
      }
    }
    return try results.value()
  }

  private func validateDirectoryContents() throws {
    guard let enumerator = FileManager.default.enumerator(atPath: root.path) else {
      throw EmbeddedDSHRuntimeError.resourcesUnavailable
    }
    var seenFiles = Set<String>()
    var seenLinks = Set<String>()
    while let path = enumerator.nextObject() as? String {
      let normalized = path.replacingOccurrences(of: "\\", with: "/")
      if normalized == "runtime.json" { continue }
      guard Self.validPath(normalized) else { throw EmbeddedDSHRuntimeError.invalidManifest }
      let url = root.appendingPathComponent(normalized)
      let attributes: [FileAttributeKey: Any]
      do { attributes = try FileManager.default.attributesOfItem(atPath: url.path) } catch {
        throw EmbeddedDSHRuntimeError.resourceChanged(normalized)
      }
      switch attributes[.type] as? FileAttributeType {
      case .typeDirectory:
        continue
      case .typeRegular:
        guard files[key(normalized)] != nil, seenFiles.insert(key(normalized)).inserted else {
          throw EmbeddedDSHRuntimeError.resourceChanged(normalized)
        }
      case .typeSymbolicLink:
        guard links[key(normalized)] != nil, seenLinks.insert(key(normalized)).inserted else {
          throw EmbeddedDSHRuntimeError.resourceChanged(normalized)
        }
      default:
        throw EmbeddedDSHRuntimeError.resourceChanged(normalized)
      }
    }
    guard seenFiles.count == files.count, seenLinks.count == links.count else {
      throw EmbeddedDSHRuntimeError.invalidManifest
    }
  }

  private func validateLink(_ link: Manifest.Link) throws {
    let url = root.appendingPathComponent(link.path)
    do {
      guard try FileManager.default.destinationOfSymbolicLink(atPath: url.path) == link.target,
        FileManager.default.fileExists(atPath: url.path),
        AgentPathSemantics.isContained(
          url.resolvingSymlinksInPath().standardizedFileURL.path, in: root.path)
      else { throw EmbeddedDSHRuntimeError.resourceChanged(link.path) }
    } catch let error as EmbeddedDSHRuntimeError {
      throw error
    } catch {
      throw EmbeddedDSHRuntimeError.resourceChanged(link.path)
    }
  }

  private func validateFile(
    _ file: Manifest.File, requiresExecutable: Bool
  ) throws -> SecureFileArtifactSnapshot? {
    let url = root.appendingPathComponent(file.path)
    let resolved = url.resolvingSymlinksInPath().standardizedFileURL
    guard AgentPathSemantics.isContained(resolved.path, in: root.path) else {
      throw EmbeddedDSHRuntimeError.resourceChanged(file.path)
    }
    do {
      let attributes = try FileManager.default.attributesOfItem(atPath: resolved.path)
      guard attributes[.type] as? FileAttributeType == .typeRegular,
        let size = (attributes[.size] as? NSNumber)?.uint64Value
      else { throw EmbeddedDSHRuntimeError.resourceChanged(file.path) }
      if size == 0 {
        guard !requiresExecutable, file.sha256 == Self.emptySHA256 else {
          throw EmbeddedDSHRuntimeError.resourceChanged(file.path)
        }
        guard try SecureFileArtifactReader.read(at: resolved.path, maximumBytes: 1).isEmpty else {
          throw EmbeddedDSHRuntimeError.resourceChanged(file.path)
        }
        return nil
      }
      let snapshot = try SecureFileArtifactSnapshot.capture(
        at: resolved.path, requiresExecutable: requiresExecutable)
      guard snapshot.sha256 == file.sha256 else {
        throw EmbeddedDSHRuntimeError.resourceChanged(file.path)
      }
      return snapshot
    } catch let error as EmbeddedDSHRuntimeError {
      throw error
    } catch {
      throw EmbeddedDSHRuntimeError.resourceChanged(file.path)
    }
  }

  private static func validPath(_ path: String) -> Bool {
    !path.isEmpty && path.utf8.count <= 16 * 1_024 && !path.contains("\\")
      && path.rangeOfCharacter(from: .controlCharacters) == nil
      && AgentPathSemantics.relativeComponents(path) != nil
  }

  private static func pathKey(_ path: String) -> String {
    #if os(Windows)
      path.lowercased()
    #else
      path
    #endif
  }

  private static func validDigest(_ digest: String) -> Bool {
    digest.utf8.count == 64
      && digest.utf8.allSatisfy {
        (48...57).contains($0) || (97...102).contains($0)
      }
  }

  private static let emptySHA256 = SHA256.hash(data: Data())
    .map { String(format: "%02x", $0) }.joined()
}

private final class ValidationResults: @unchecked Sendable {
  private let lock = NSLock()
  private var entrypoints: [String: SecureFileArtifactSnapshot] = [:]
  private var failure: (any Error)?

  func append(_ values: [String: SecureFileArtifactSnapshot]) {
    lock.withLock { entrypoints.merge(values) { previous, _ in previous } }
  }

  func fail(_ error: any Error) {
    lock.withLock { if failure == nil { failure = error } }
  }

  func value() throws -> [String: SecureFileArtifactSnapshot] {
    try lock.withLock {
      if let failure { throw failure }
      return entrypoints
    }
  }
}
