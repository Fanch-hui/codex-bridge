import BridgeAgentCore
import BridgeSecurity
import Foundation

struct PiSessionBinding: Codable, Equatable, Sendable {
  let projectID: String
  let projectRoot: String
  let installationID: String
  let sessionID: String
  let sessionFile: String
}

struct PiSessionStore: Sendable {
  let resolver: ProjectPathResolver
  let sessionsDirectory: String
  private let namespace: String

  init(baseDirectory: String, installationID: String, projectID: String) throws {
    let root = try RegisteredRoot(capturing: URL(fileURLWithPath: baseDirectory))
    resolver = ProjectPathResolver(root: root)
    namespace =
      SecureFileRevision.digest(
        of: try JSONEncoder().encode([installationID, projectID])
      ).sha256
    for path in [
      namespace, namespace + "/sessions", namespace + "/bindings", namespace + "/native-bindings",
    ] {
      let relative = try SecureRelativePath(path)
      let url = URL(fileURLWithPath: root.canonicalPath).appendingPathComponent(path)
      if !FileManager.default.fileExists(atPath: url.path) {
        _ = try SecureProjectDirectoryMutation().apply(
          action: .createDirectory, relativePath: relative,
          destinationRelativePath: nil, through: resolver)
      }
      _ = try resolver.resolve(relative)
    }
    sessionsDirectory =
      URL(fileURLWithPath: root.canonicalPath)
      .appendingPathComponent(namespace + "/sessions", isDirectory: true).path
  }

  func load(sessionID: String, request: AgentExecutionRequest, installation: AgentInstallation)
    throws -> PiSessionBinding
  {
    let reader = SecureFileReader(maximumBytes: 32 * 1_024, maximumLines: 100)
    let writer = SecureProjectFileWriter(maximumBytes: 32 * 1_024)
    let localPath = try bindingPath(sessionID)
    let nativePath = try nativeBindingPath(sessionID)
    let isNative: Bool
    let path: SecureRelativePath
    if try writer.revision(relativePath: localPath, through: resolver) != nil {
      isNative = false
      path = localPath
    } else if try writer.revision(relativePath: nativePath, through: resolver) != nil {
      isNative = true
      path = nativePath
    } else {
      throw AgentRuntimeError.sessionMismatch
    }
    let text = try reader.read(path, through: resolver)
    let binding = try JSONDecoder().decode(PiSessionBinding.self, from: Data(text.text.utf8))
    let sessionFileIsValid =
      isNative
      ? Self.isNativeSessionFile(binding.sessionFile)
      : AgentPathSemantics.isContained(binding.sessionFile, in: sessionsDirectory)
    guard binding.projectID == request.projectID.rawValue,
      binding.installationID == installation.id.rawValue, binding.sessionID == sessionID,
      Self.samePath(binding.projectRoot, request.projectRoot),
      sessionFileIsValid,
      FileManager.default.fileExists(atPath: binding.sessionFile)
    else { throw AgentRuntimeError.sessionMismatch }
    if !isNative {
      guard
        let relative = AgentPathSemantics.relativePath(
          binding.sessionFile, from: resolver.root.canonicalPath)
      else { throw AgentRuntimeError.sessionMismatch }
      _ = try resolver.resolve(SecureRelativePath(relative))
    }
    return binding
  }

  func saveNativeIndex(_ binding: PiSessionBinding) throws {
    guard Self.isNativeSessionFile(binding.sessionFile),
      FileManager.default.fileExists(atPath: binding.sessionFile)
    else { throw AgentRuntimeError.sessionMismatch }
    let path = try nativeBindingPath(binding.sessionID)
    let writer = SecureProjectFileWriter(maximumBytes: 32 * 1_024)
    let bridgePath = try bindingPath(binding.sessionID)
    if try writer.revision(relativePath: bridgePath, through: resolver) != nil {
      let text = try SecureFileReader(maximumBytes: 32 * 1_024, maximumLines: 100)
        .read(bridgePath, through: resolver)
      let existing = try JSONDecoder().decode(PiSessionBinding.self, from: Data(text.text.utf8))
      guard existing == binding else { throw AgentRuntimeError.sessionMismatch }
    }
    if try writer.revision(relativePath: path, through: resolver) != nil {
      let text = try SecureFileReader(maximumBytes: 32 * 1_024, maximumLines: 100)
        .read(path, through: resolver)
      let previous = try JSONDecoder().decode(PiSessionBinding.self, from: Data(text.text.utf8))
      guard previous == binding else { throw AgentRuntimeError.sessionMismatch }
      return
    }
    _ = try writer.write(
      relativePath: path, through: resolver, mode: .create,
      content: JSONEncoder().encode(binding), expectedSHA256: nil, createParents: false)
  }

  func isIndexed(sessionID: String, expected: PiSessionBinding) throws -> Bool {
    let reader = SecureFileReader(maximumBytes: 32 * 1_024, maximumLines: 100)
    let writer = SecureProjectFileWriter(maximumBytes: 32 * 1_024)
    let path = try nativeBindingPath(sessionID)
    guard try writer.revision(relativePath: path, through: resolver) != nil else { return false }
    let text = try reader.read(path, through: resolver)
    guard try JSONDecoder().decode(PiSessionBinding.self, from: Data(text.text.utf8)) == expected
    else { throw AgentRuntimeError.sessionMismatch }
    return true
  }

  func removeIndex(sessionID: String, expected: PiSessionBinding) throws {
    let reader = SecureFileReader(maximumBytes: 32 * 1_024, maximumLines: 100)
    let writer = SecureProjectFileWriter(maximumBytes: 32 * 1_024)
    let mutation = SecureProjectDirectoryMutation(maximumBytes: 32 * 1_024)
    let path = try nativeBindingPath(sessionID)
    guard try writer.revision(relativePath: path, through: resolver) != nil else { return }
    let text = try reader.read(path, through: resolver)
    guard try JSONDecoder().decode(PiSessionBinding.self, from: Data(text.text.utf8)) == expected
    else { throw AgentRuntimeError.sessionMismatch }
    _ = try mutation.apply(
      action: .deleteFile(expectedSHA256: text.sha256), relativePath: path,
      destinationRelativePath: nil, through: resolver)
  }

  func save(_ binding: PiSessionBinding) throws {
    guard AgentPathSemantics.isContained(binding.sessionFile, in: sessionsDirectory),
      !Self.samePath(binding.sessionFile, sessionsDirectory)
    else { throw AgentRuntimeError.sessionMismatch }
    let path = try bindingPath(binding.sessionID)
    let writer = SecureProjectFileWriter(maximumBytes: 32 * 1_024)
    let revision = try writer.revision(relativePath: path, through: resolver)
    if revision != nil {
      let text = try SecureFileReader(maximumBytes: 32 * 1_024, maximumLines: 100)
        .read(path, through: resolver)
      let previous = try JSONDecoder().decode(PiSessionBinding.self, from: Data(text.text.utf8))
      guard previous == binding else { throw AgentRuntimeError.sessionMismatch }
      return
    }
    _ = try writer.write(
      relativePath: path, through: resolver, mode: .create,
      content: JSONEncoder().encode(binding), expectedSHA256: nil, createParents: false)
  }

  private func bindingPath(_ id: String) throws -> SecureRelativePath {
    guard !id.isEmpty, id.utf8.count <= 1_024, !id.contains("\0") else {
      throw AgentRuntimeError.sessionMismatch
    }
    return try SecureRelativePath(namespace + "/bindings/" + Self.bindingKey(id) + ".json")
  }

  private func nativeBindingPath(_ id: String) throws -> SecureRelativePath {
    guard !id.isEmpty, id.utf8.count <= 1_024, !id.contains("\0") else {
      throw AgentRuntimeError.sessionMismatch
    }
    return try SecureRelativePath(namespace + "/native-bindings/" + Self.bindingKey(id) + ".json")
  }

  private static func bindingKey(_ id: String) -> String {
    SecureFileRevision.digest(of: Data(id.utf8)).sha256
  }

  private static func isNativeSessionFile(_ path: String) -> Bool {
    guard AgentPathSemantics.isAbsolute(path), !path.contains("\0"),
      URL(fileURLWithPath: path).pathExtension.lowercased() == "jsonl"
    else { return false }
    let url = URL(fileURLWithPath: path).standardizedFileURL
    return url.path == url.resolvingSymlinksInPath().standardizedFileURL.path
  }

  static func samePath(_ lhs: String, _ rhs: String) -> Bool {
    AgentPathSemantics.isContained(lhs, in: rhs) && AgentPathSemantics.isContained(rhs, in: lhs)
  }
}
