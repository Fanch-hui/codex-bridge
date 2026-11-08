import BridgeAgentCore
import BridgeSecurity
import Foundation

struct ClaudeSessionBinding: Codable, Equatable, Sendable {
  let sessionID: String
  let installationID: String
  let projectID: String
  let projectRoot: RegisteredRoot
  let configScopeDigest: String
}

struct ClaudeSessionStore: Sendable {
  private let resolver: ProjectPathResolver

  init(directory: String) throws {
    #if os(Windows)
      let attributes: [FileAttributeKey: Any]? = nil
    #else
      let attributes: [FileAttributeKey: Any]? = [.posixPermissions: 0o700]
    #endif
    try FileManager.default.createDirectory(
      atPath: directory, withIntermediateDirectories: true, attributes: attributes)
    resolver = ProjectPathResolver(
      root: try RegisteredRoot(capturing: URL(fileURLWithPath: directory)))
  }

  var directory: String { resolver.root.canonicalPath }

  func binding(
    request: AgentExecutionRequest, installation: AgentInstallation, sessionID: String,
    configScopeDigest: String
  ) throws -> ClaudeSessionBinding {
    guard UUID(uuidString: sessionID) != nil,
      configScopeDigest.utf8.count == 64,
      configScopeDigest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
    else { throw AgentRuntimeError.sessionMismatch }
    let root = try RegisteredRoot(capturing: URL(fileURLWithPath: request.projectRoot))
    let result = ClaudeSessionBinding(
      sessionID: sessionID, installationID: installation.id.rawValue,
      projectID: request.projectID.rawValue, projectRoot: root, configScopeDigest: configScopeDigest
    )
    let relative = try path(result)
    let writer = SecureProjectFileWriter(maximumBytes: 32768)
    guard try writer.revision(relativePath: relative, through: resolver) != nil else {
      guard request.requestedSessionID == nil else { throw AgentRuntimeError.sessionMismatch }
      return result
    }
    let file = try SecureFileReader(maximumBytes: 32768, maximumLines: 100)
      .read(relative, through: resolver)
    guard try JSONDecoder().decode(ClaudeSessionBinding.self, from: Data(file.text.utf8)) == result
    else { throw AgentRuntimeError.sessionMismatch }
    return result
  }

  func save(_ binding: ClaudeSessionBinding) throws {
    let path = try path(binding)
    let writer = SecureProjectFileWriter(maximumBytes: 32768)
    if try writer.revision(relativePath: path, through: resolver) != nil {
      let file = try SecureFileReader(maximumBytes: 32768, maximumLines: 100)
        .read(path, through: resolver)
      guard
        try JSONDecoder().decode(ClaudeSessionBinding.self, from: Data(file.text.utf8)) == binding
      else { throw AgentRuntimeError.sessionMismatch }
      return
    }
    _ = try writer.write(
      relativePath: path, through: resolver, mode: .create,
      content: JSONEncoder().encode(binding), expectedSHA256: nil, createParents: false)
  }

  private func path(_ binding: ClaudeSessionBinding) throws -> SecureRelativePath {
    let key = try JSONEncoder().encode([
      binding.installationID, binding.projectID, binding.sessionID,
    ])
    return try SecureRelativePath(SecureFileRevision.digest(of: key).sha256 + ".json")
  }
}

actor ClaudeSessionLeases {
  static let shared = ClaudeSessionLeases()
  private var active = Set<String>()

  func acquire(installationID: String, sessionID: String) throws -> String {
    let key = installationID + "\0" + sessionID
    guard active.insert(key).inserted else {
      throw AgentRuntimeError.invalidRequest("claude.session_busy")
    }
    return key
  }

  func release(_ key: String) { active.remove(key) }
}
