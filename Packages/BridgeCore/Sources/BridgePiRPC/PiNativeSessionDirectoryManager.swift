import BridgeAgentCore
import BridgeProcess
import BridgeSecurity
import Foundation

public struct PiNativeSessionDirectoryManager: AgentNativeSessionDirectoryManaging, Sendable {
  private let configuration: PiRPCProviderConfiguration

  public init(configuration: PiRPCProviderConfiguration) {
    self.configuration = configuration
  }

  public func listNativeSessions(
    scope: AgentNativeSessionDirectoryScope,
    installation: AgentInstallation,
    page: AgentNativeSessionPageRequest
  ) async throws -> AgentNativeSessionPage {
    let context = try context(scope: scope, installation: installation)
    let value = try await request("list", scope: scope, context: context, page: page)
    guard let values = value["sessions"]?.arrayValue else {
      throw AgentNativeSessionDirectoryError.runtimeFailure
    }
    let sessions = try values.compactMap { item -> AgentNativeSessionSummary? in
      guard let item = item.objectValue else { return nil }
      let sessionID = try requiredString("sessionID", in: item)
      let sessionPath = try requiredString("sessionPath", in: item)
      let indexed = try context.store.isIndexed(
        sessionID: sessionID,
        expected: binding(
          sessionID: sessionID, sessionFile: sessionPath, scope: scope,
          installation: installation, projectRoot: context.projectRoot))
      return try summary(item, isIndexed: indexed)
    }
    return AgentNativeSessionPage(sessions: sessions, nextOffset: value["nextOffset"]?.integerValue)
  }

  public func readNativeSession(
    sessionID: String,
    scope: AgentNativeSessionDirectoryScope,
    installation: AgentInstallation,
    page: AgentNativeSessionPageRequest
  ) async throws -> AgentNativeSessionTranscriptPage {
    let context = try context(scope: scope, installation: installation)
    let value = try await request(
      "read", scope: scope, context: context, page: page, sessionID: sessionID)
    guard value["sessionID"]?.stringValue == sessionID, let entries = value["messages"]?.arrayValue
    else { throw AgentNativeSessionDirectoryError.scopeMismatch }
    let messages = try entries.compactMap { entry -> AgentNativeSessionMessage? in
      guard let item = entry.objectValue else { return nil }
      return try AgentNativeSessionMessage(
        messageID: requiredString("messageID", in: item), role: requiredString("role", in: item),
        content: requiredString("content", in: item),
        createdAt: parseDate(item["createdAt"]?.stringValue))
    }
    return AgentNativeSessionTranscriptPage(
      sessionID: sessionID, messages: messages, nextOffset: value["nextOffset"]?.integerValue)
  }

  public func renameNativeSession(
    sessionID: String,
    title: String,
    scope: AgentNativeSessionDirectoryScope,
    installation: AgentInstallation
  ) async throws -> AgentNativeSessionSummary {
    let context = try context(scope: scope, installation: installation)
    let value = try await request(
      "rename", scope: scope, context: context, sessionID: sessionID, title: title)
    let verified = try await request("verify", scope: scope, context: context, sessionID: sessionID)
    let sessionPath = try requiredString("sessionPath", in: verified.objectValue ?? [:])
    let indexed = try context.store.isIndexed(
      sessionID: sessionID,
      expected: binding(
        sessionID: sessionID, sessionFile: sessionPath, scope: scope,
        installation: installation, projectRoot: context.projectRoot))
    return try summary(value.objectValue ?? [:], isIndexed: indexed)
  }

  public func deleteNativeSession(
    sessionID: String,
    scope: AgentNativeSessionDirectoryScope,
    installation: AgentInstallation
  ) async throws {
    let context = try context(scope: scope, installation: installation)
    let verified = try await request("verify", scope: scope, context: context, sessionID: sessionID)
    let sessionPath = try requiredString("sessionPath", in: verified.objectValue ?? [:])
    _ = try await request("delete", scope: scope, context: context, sessionID: sessionID)
    try context.store.removeIndex(
      sessionID: sessionID,
      expected: binding(
        sessionID: sessionID, sessionFile: sessionPath, scope: scope, installation: installation,
        projectRoot: context.projectRoot))
  }

  public func indexNativeSession(
    sessionID: String,
    scope: AgentNativeSessionDirectoryScope,
    installation: AgentInstallation
  ) async throws -> AgentNativeSessionIndexReceipt {
    let context = try context(scope: scope, installation: installation)
    let value = try await request("verify", scope: scope, context: context, sessionID: sessionID)
    let sessionPath = try requiredString("sessionPath", in: value.objectValue ?? [:])
    try context.store.saveNativeIndex(
      binding(
        sessionID: sessionID, sessionFile: sessionPath, scope: scope, installation: installation,
        projectRoot: context.projectRoot))
    return AgentNativeSessionIndexReceipt(scope: scope, sessionID: sessionID)
  }

  public func isIndexedNativeSession(
    sessionID: String,
    scope: AgentNativeSessionDirectoryScope,
    installation: AgentInstallation
  ) async throws -> Bool {
    let context = try context(scope: scope, installation: installation)
    let value = try await request("verify", scope: scope, context: context, sessionID: sessionID)
    let sessionPath = try requiredString("sessionPath", in: value.objectValue ?? [:])
    return try context.store.isIndexed(
      sessionID: sessionID,
      expected: binding(
        sessionID: sessionID, sessionFile: sessionPath, scope: scope,
        installation: installation, projectRoot: context.projectRoot))
  }

  private func context(scope: AgentNativeSessionDirectoryScope, installation: AgentInstallation)
    throws
    -> (
      node: String, packageRoot: String, projectRoot: String, store: PiSessionStore, script: String,
      environment: [String: String]
    )
  {
    guard scope.providerID == .pi, installation.providerID == .pi,
      scope.installationID == installation.id, scope.region == nil
    else { throw AgentNativeSessionDirectoryError.scopeMismatch }
    let projectRoot = try RegisteredRoot(capturing: URL(fileURLWithPath: scope.projectRoot))
      .canonicalPath
    guard AgentPathSemantics.isContained(projectRoot, in: scope.projectRoot),
      AgentPathSemantics.isContained(scope.projectRoot, in: projectRoot)
    else { throw AgentNativeSessionDirectoryError.scopeMismatch }
    let executable = try SecureFileArtifactSnapshot.capture(at: installation.executablePath)
    guard
      let nodePath = AgentNodeExecutableResolver.resolve(
        near: installation.executablePath, environment: configuration.sourceEnvironment)
    else { throw AgentNativeSessionDirectoryError.unavailable }
    let node = try SecureFileArtifactSnapshot.capture(at: nodePath, requiresExecutable: true)
    let resolution = try PiExecutableResolver.resolve(executable: executable, node: node)
    guard let manifest = resolution.manifest else {
      throw AgentNativeSessionDirectoryError.unavailable
    }
    let resources = try PiNativeHistoryResources.load()
    let home = try AgentProviderEnvironment.homeDirectory(source: configuration.sourceEnvironment)
    var environment = [
      "HOME": home,
      "PATH": AgentProviderEnvironment.executableSearchPath(
        executablePath: node.canonicalPath, source: configuration.sourceEnvironment),
      "PI_OFFLINE": "1",
    ]
    #if os(Windows)
      AgentProviderEnvironment.applyWindowsSystemEnvironment(
        to: &environment, from: configuration.sourceEnvironment)
      environment["USERPROFILE"] = home
    #endif
    for key in ["USER", "LOGNAME", "LANG", "LC_ALL", "TEMP", "TMP", "TMPDIR"] {
      if let value = configuration.sourceEnvironment[key], !value.contains("\0"),
        value.utf8.count <= 32 * 1_024
      {
        environment[key] = value
      }
    }
    let store = try PiSessionStore(
      baseDirectory: configuration.runtimeBaseDirectory,
      installationID: installation.id.rawValue, projectID: scope.projectID)
    return (
      node.canonicalPath,
      URL(fileURLWithPath: manifest.canonicalPath).deletingLastPathComponent().path,
      projectRoot, store, resources.script.canonicalPath, environment
    )
  }

  private func request(
    _ operation: String,
    scope: AgentNativeSessionDirectoryScope,
    context: (
      node: String, packageRoot: String, projectRoot: String, store: PiSessionStore, script: String,
      environment: [String: String]
    ),
    page: AgentNativeSessionPageRequest? = nil,
    sessionID: String? = nil,
    title: String? = nil
  ) async throws -> PiJSONValue {
    var fields: [String: PiJSONValue] = [
      "revision": .integer(1), "operation": .string(operation), "cwd": .string(context.projectRoot),
      "sessionDirectory": .string(context.store.sessionsDirectory),
      "packageRoot": .string(context.packageRoot),
    ]
    if let page {
      fields["offset"] = .integer(Int64(page.offset))
      fields["limit"] = .integer(Int64(page.limit))
    }
    if let sessionID { fields["sessionID"] = .string(sessionID) }
    if let title { fields["title"] = .string(title) }
    let input = try PiJSONValue.object(fields).encoded()
    let output = PiNativeHistoryOutput(maximumBytes: 8 * 1_024 * 1_024)
    let process = try ManagedStdioProcess(
      argv: [context.node, context.script], workingDirectory: context.projectRoot,
      environment: context.environment, mergeStandardError: false,
      onStandardOutput: { output.append($0) })
    do {
      try process.writeStdin(input + Data([0x0A]), timeout: .seconds(5))
      process.closeStdin()
      let result = await ManagedProcessRunner(defaultTimeout: .seconds(30)).monitor(
        process: process)
      guard result.termination == .exited(0), !result.timedOut else {
        throw AgentNativeSessionDirectoryError.runtimeFailure
      }
      guard let data = output.snapshot(),
        let frame = try? JSONDecoder().decode(PiJSONValue.self, from: data),
        let value = frame.objectValue
      else { throw AgentNativeSessionDirectoryError.runtimeFailure }
      if let error = value["error"]?.stringValue {
        switch error {
        case "native_session_not_found": throw AgentNativeSessionDirectoryError.sessionNotFound
        case "ambiguous_native_session", "native_session_path_changed",
          "native_session_not_regular_file":
          throw AgentNativeSessionDirectoryError.scopeMismatch
        default: throw AgentNativeSessionDirectoryError.runtimeFailure
        }
      }
      guard let result = value["result"] else {
        throw AgentNativeSessionDirectoryError.runtimeFailure
      }
      return result
    } catch {
      process.terminateGroup()
      process.close()
      throw error
    }
  }

  private func binding(
    sessionID: String,
    sessionFile: String,
    scope: AgentNativeSessionDirectoryScope,
    installation: AgentInstallation,
    projectRoot: String
  ) -> PiSessionBinding {
    PiSessionBinding(
      projectID: scope.projectID, projectRoot: projectRoot,
      installationID: installation.id.rawValue, sessionID: sessionID, sessionFile: sessionFile)
  }

  private func summary(_ value: [String: PiJSONValue], isIndexed: Bool) throws
    -> AgentNativeSessionSummary
  {
    try AgentNativeSessionSummary(
      sessionID: requiredString("sessionID", in: value), title: requiredString("title", in: value),
      firstPrompt: value["firstPrompt"]?.stringValue,
      createdAt: parseDate(value["createdAt"]?.stringValue),
      updatedAt: parseDate(value["updatedAt"]?.stringValue),
      messageCount: value["messageCount"]?.integerValue ?? 0, isIndexed: isIndexed)
  }

  private func requiredString(_ key: String, in value: [String: PiJSONValue]) throws -> String {
    guard let string = value[key]?.stringValue else {
      throw AgentNativeSessionDirectoryError.runtimeFailure
    }
    return string
  }

  private func parseDate(_ value: String?) -> Date? {
    guard let value else { return nil }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
  }
}

private final class PiNativeHistoryOutput: @unchecked Sendable {
  private let lock = NSLock()
  private let maximumBytes: Int
  private var bytes = Data()
  private var overflowed = false

  init(maximumBytes: Int) { self.maximumBytes = maximumBytes }

  func append(_ value: Data) {
    lock.lock()
    defer { lock.unlock() }
    guard !overflowed else { return }
    guard value.count <= maximumBytes - bytes.count else {
      overflowed = true
      return
    }
    bytes.append(value)
  }

  func snapshot() -> Data? {
    lock.lock()
    defer { lock.unlock() }
    return overflowed ? nil : bytes
  }
}
