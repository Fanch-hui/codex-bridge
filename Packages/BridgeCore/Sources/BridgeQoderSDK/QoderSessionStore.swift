import BridgeAgentCore
import BridgeSecurity
import Foundation

struct QoderSessionBinding: Codable, Equatable, Sendable {
  let sessionID: String
  let distribution: QoderDistribution
  let installationID: String
  let projectID: String
  let projectRoot: String
  let accountScope: String

  private enum CodingKeys: String, CodingKey {
    case sessionID, distribution, installationID, projectID, projectRoot, accountScope
  }

  init(
    sessionID: String,
    distribution: QoderDistribution,
    installationID: String,
    projectID: String,
    projectRoot: String,
    accountScope: String
  ) {
    self.sessionID = sessionID
    self.distribution = distribution
    self.installationID = installationID
    self.projectID = projectID
    self.projectRoot = projectRoot
    self.accountScope = accountScope
  }

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    sessionID = try values.decode(String.self, forKey: .sessionID)
    distribution = try values.decode(QoderDistribution.self, forKey: .distribution)
    installationID = try values.decode(String.self, forKey: .installationID)
    projectID = try values.decode(String.self, forKey: .projectID)
    projectRoot = try values.decode(String.self, forKey: .projectRoot)
    accountScope = try values.decodeIfPresent(String.self, forKey: .accountScope) ?? ""
  }
}

enum QoderSessionIndexState: Equatable {
  case missing
  case current
  case otherAccount
  case unbound
}

struct QoderSessionStore: Sendable {
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

  func previousBinding(
    request: AgentExecutionRequest, installation: AgentInstallation, distribution: QoderDistribution
  )
    throws -> QoderSessionBinding?
  {
    guard let id = request.requestedSessionID else { return nil }
    guard UUID(uuidString: id) != nil else { throw AgentRuntimeError.sessionMismatch }
    let expected = QoderSessionBinding(
      sessionID: id, distribution: distribution,
      installationID: installation.id.rawValue, projectID: request.projectID.rawValue,
      projectRoot: request.projectRoot, accountScope: "")
    let file = try SecureFileReader(maximumBytes: 32768, maximumLines: 100).read(
      path(expected), through: resolver)
    let saved = try JSONDecoder().decode(QoderSessionBinding.self, from: Data(file.text.utf8))
    guard saved.sessionID == id, saved.distribution == distribution,
      Self.isAccountScope(saved.accountScope),
      saved.installationID == expected.installationID, saved.projectID == expected.projectID,
      AgentPathSemantics.isContained(saved.projectRoot, in: expected.projectRoot),
      AgentPathSemantics.isContained(expected.projectRoot, in: saved.projectRoot)
    else { throw AgentRuntimeError.sessionMismatch }
    return saved
  }

  func binding(
    request: AgentExecutionRequest,
    installation: AgentInstallation,
    distribution: QoderDistribution,
    accountScope: String,
    sessionID: String? = nil
  ) throws -> QoderSessionBinding {
    guard Self.isAccountScope(accountScope) else { throw AgentRuntimeError.sessionMismatch }
    let id = request.requestedSessionID ?? sessionID ?? UUID().uuidString.lowercased()
    guard UUID(uuidString: id) != nil else { throw AgentRuntimeError.sessionMismatch }
    guard request.requestedSessionID == nil || request.requestedSessionID == id else {
      throw AgentRuntimeError.sessionMismatch
    }
    let expected = QoderSessionBinding(
      sessionID: id, distribution: distribution,
      installationID: installation.id.rawValue, projectID: request.projectID.rawValue,
      projectRoot: request.projectRoot, accountScope: accountScope)
    guard
      let previous = try previousBinding(
        request: request, installation: installation, distribution: distribution)
    else { return expected }
    guard previous == expected else { throw AgentRuntimeError.sessionMismatch }
    return previous
  }

  func save(_ binding: QoderSessionBinding) throws {
    let path = try path(binding)
    let writer = SecureProjectFileWriter(maximumBytes: 32768)
    if try writer.revision(relativePath: path, through: resolver) != nil {
      let file = try SecureFileReader(maximumBytes: 32768, maximumLines: 100).read(
        path, through: resolver)
      guard
        try JSONDecoder().decode(QoderSessionBinding.self, from: Data(file.text.utf8)) == binding
      else { throw AgentRuntimeError.sessionMismatch }
      return
    }
    _ = try writer.write(
      relativePath: path, through: resolver, mode: .create,
      content: JSONEncoder().encode(binding), expectedSHA256: nil, createParents: false)
  }

  func containsIndex(_ binding: QoderSessionBinding) throws -> Bool {
    try indexState(binding) == .current
  }

  func indexState(_ binding: QoderSessionBinding) throws -> QoderSessionIndexState {
    let relativePath = try path(binding)
    let reader = SecureFileReader(maximumBytes: 32_768, maximumLines: 100)
    guard
      let revision = try SecureProjectFileWriter(maximumBytes: 32_768)
        .revision(relativePath: relativePath, through: resolver)
    else { return .missing }
    let file = try reader.read(relativePath, through: resolver)
    guard file.sha256 == revision.sha256 else { throw AgentRuntimeError.sessionMismatch }
    let saved = try JSONDecoder().decode(QoderSessionBinding.self, from: Data(file.text.utf8))
    guard Self.matches(saved, binding) else { throw AgentRuntimeError.sessionMismatch }
    if saved.accountScope.isEmpty { return .unbound }
    guard Self.isAccountScope(saved.accountScope) else { throw AgentRuntimeError.sessionMismatch }
    return saved.accountScope == binding.accountScope ? .current : .otherAccount
  }

  func requireCurrentOrMissing(_ binding: QoderSessionBinding) throws {
    let state = try indexState(binding)
    guard state == .current || state == .missing else {
      throw AgentRuntimeError.sessionMismatch
    }
  }

  func removeIndex(_ binding: QoderSessionBinding) throws {
    let relativePath = try path(binding)
    guard
      try SecureProjectFileWriter(maximumBytes: 32_768)
        .revision(relativePath: relativePath, through: resolver) != nil
    else { return }
    let file = try SecureFileReader(maximumBytes: 32_768, maximumLines: 100)
      .read(relativePath, through: resolver)
    guard try JSONDecoder().decode(QoderSessionBinding.self, from: Data(file.text.utf8)) == binding
    else { throw AgentRuntimeError.sessionMismatch }
    _ = try SecureProjectDirectoryMutation(maximumBytes: 32_768).apply(
      action: .deleteFile(expectedSHA256: file.sha256), relativePath: relativePath,
      destinationRelativePath: nil, through: resolver)
  }

  private func path(_ binding: QoderSessionBinding) throws -> SecureRelativePath {
    let digest = SecureFileRevision.digest(
      of: try JSONEncoder().encode([
        binding.distribution.rawValue, binding.installationID, binding.projectID, binding.sessionID,
      ])
    ).sha256
    return try SecureRelativePath(digest + ".json")
  }

  private static func matches(_ saved: QoderSessionBinding, _ expected: QoderSessionBinding) -> Bool
  {
    saved.sessionID == expected.sessionID && saved.distribution == expected.distribution
      && saved.installationID == expected.installationID && saved.projectID == expected.projectID
      && AgentPathSemantics.isContained(saved.projectRoot, in: expected.projectRoot)
      && AgentPathSemantics.isContained(expected.projectRoot, in: saved.projectRoot)
  }

  private static func isAccountScope(_ value: String) -> Bool {
    value.utf8.count == 64
      && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
  }
}
