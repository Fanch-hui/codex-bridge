import BridgeACP
import BridgeAgentCore
import Foundation

public struct DeepSeekHarnessDesktopSessionDirectory: AgentNativeSessionDirectoryManaging, Sendable
{
  let controller: DeepSeekHarnessDesktopController
  let configuration: DeepSeekHarnessDesktopConfiguration
  let modeProvider: (@Sendable (AgentInstallationID) async throws -> DeepSeekHarnessConnectionMode)?

  public init(
    controller: DeepSeekHarnessDesktopController,
    configuration: DeepSeekHarnessDesktopConfiguration,
    modeProvider: (@Sendable (AgentInstallationID) async throws -> DeepSeekHarnessConnectionMode)? =
      nil
  ) {
    self.controller = controller
    self.configuration = configuration
    self.modeProvider = modeProvider
  }

  public func listNativeSessions(
    scope: AgentNativeSessionDirectoryScope,
    installation: AgentInstallation, page: AgentNativeSessionPageRequest
  ) async throws
    -> AgentNativeSessionPage
  {
    let client = try await checkedClient(scope: scope, installation: installation)
    let result = try await client.call(
      "session/list", params: ["projectPath": .string(scope.projectRoot)])
    guard let sessions = result["sessions"]?.arrayValue else {
      throw AgentNativeSessionDirectoryError.runtimeFailure
    }
    let selected = sessions.dropFirst(page.offset).prefix(page.limit)
    var summaries: [AgentNativeSessionSummary] = []
    for item in selected {
      try verify(item, scope: scope)
      let id = try required(item, "sessionID")
      let indexed = try await configuration.indexLookup(scope, client.descriptor.profileID, id)
      summaries.append(try summary(item, indexed: indexed))
    }
    let next = page.offset + summaries.count
    return AgentNativeSessionPage(
      sessions: summaries,
      nextOffset: next < sessions.count ? next : nil)
  }

  public func readNativeSession(
    sessionID: String, scope: AgentNativeSessionDirectoryScope,
    installation: AgentInstallation, page: AgentNativeSessionPageRequest
  ) async throws
    -> AgentNativeSessionTranscriptPage
  {
    let client = try await checkedClient(scope: scope, installation: installation)
    let value = try await client.call(
      "session/read",
      params: [
        "projectPath": .string(scope.projectRoot), "sessionID": .string(sessionID),
        "offset": .integer(Int64(page.offset)), "limit": .integer(Int64(page.limit)),
      ])
    try verify(value, scope: scope)
    guard value["sessionID"]?.stringValue == sessionID, let messages = value["messages"]?.arrayValue
    else { throw AgentNativeSessionDirectoryError.scopeMismatch }
    if let modeProvider, scope.region == nil,
      try await modeProvider(installation.id) != .nativeDesktop
    {
      throw AgentNativeSessionDirectoryError.unsupported
    }
    return AgentNativeSessionTranscriptPage(
      sessionID: sessionID,
      messages: try messages.map {
        try AgentNativeSessionMessage(
          messageID: required($0, "messageID"),
          role: required($0, "role"), content: required($0, "content", allowsEmpty: true),
          createdAt: date($0["createdAt"]?.stringValue))
      }, nextOffset: value["nextOffset"]?.intValue)
  }

  public func renameNativeSession(
    sessionID: String, title: String,
    scope: AgentNativeSessionDirectoryScope, installation: AgentInstallation
  ) async throws
    -> AgentNativeSessionSummary
  {
    let client = try await checkedClient(scope: scope, installation: installation)
    _ = try await client.call(
      "session/rename",
      params: [
        "projectPath": .string(scope.projectRoot), "sessionID": .string(sessionID),
        "title": .string(title),
      ])
    let value = try await client.call(
      "session/list", params: ["projectPath": .string(scope.projectRoot)])
    guard
      let item = value["sessions"]?.arrayValue?.first(where: {
        $0["sessionID"]?.stringValue == sessionID
      })
    else { throw AgentNativeSessionDirectoryError.sessionNotFound }
    try verify(item, scope: scope)
    let indexed = try await configuration.indexLookup(scope, client.descriptor.profileID, sessionID)
    return try summary(item, indexed: indexed)
  }

  public func deleteNativeSession(
    sessionID: String, scope: AgentNativeSessionDirectoryScope,
    installation: AgentInstallation
  ) async throws {
    throw AgentNativeSessionDirectoryError.unsupported
  }

  public func indexNativeSession(
    sessionID: String, scope: AgentNativeSessionDirectoryScope,
    installation: AgentInstallation
  ) async throws -> AgentNativeSessionIndexReceipt {
    let client = try await checkedClient(scope: scope, installation: installation)
    _ = try await readNativeSession(
      sessionID: sessionID, scope: scope, installation: installation,
      page: AgentNativeSessionPageRequest(limit: 1))
    try await configuration.indexSave(scope, client.descriptor.profileID, sessionID)
    return AgentNativeSessionIndexReceipt(scope: scope, sessionID: sessionID)
  }

  public func isIndexedNativeSession(
    sessionID: String, scope: AgentNativeSessionDirectoryScope,
    installation: AgentInstallation
  ) async throws -> Bool {
    let client = try await checkedClient(scope: scope, installation: installation)
    _ = try await readNativeSession(
      sessionID: sessionID, scope: scope, installation: installation,
      page: AgentNativeSessionPageRequest(limit: 1))
    return try await configuration.indexLookup(scope, client.descriptor.profileID, sessionID)
  }

  private func checkedClient(
    scope: AgentNativeSessionDirectoryScope, installation: AgentInstallation
  )
    async throws -> DeepSeekHarnessDesktopClient
  {
    guard scope.providerID == installation.providerID,
      [.deepSeekHarness, .deepSeekHarnessDesktop].contains(installation.providerID),
      scope.installationID == installation.id
    else { throw AgentNativeSessionDirectoryError.scopeMismatch }
    let client = try await controller.client(installation, profileID: scope.region)
    try await controller.authorizeProject(scope.projectRoot, client: client)
    return client
  }

  private func verify(_ value: ACPJSONValue, scope: AgentNativeSessionDirectoryScope) throws {
    guard let cwd = value["cwd"]?.stringValue,
      AgentPathSemantics.isContained(cwd, in: scope.projectRoot),
      AgentPathSemantics.isContained(scope.projectRoot, in: cwd)
    else { throw AgentNativeSessionDirectoryError.scopeMismatch }
  }

  private func required(_ value: ACPJSONValue, _ key: String, allowsEmpty: Bool = false) throws
    -> String
  {
    guard let text = value[key]?.stringValue, allowsEmpty || !text.isEmpty else {
      throw AgentNativeSessionDirectoryError.runtimeFailure
    }
    return text
  }

  private func summary(_ value: ACPJSONValue, indexed: Bool) throws -> AgentNativeSessionSummary {
    try AgentNativeSessionSummary(
      sessionID: required(value, "sessionID"),
      title: value["title"]?.stringValue ?? "DSH 会话",
      firstPrompt: value["firstPrompt"]?.stringValue,
      createdAt: date(value["createdAt"]?.stringValue),
      updatedAt: date(value["updatedAt"]?.stringValue),
      messageCount: value["messageCount"]?.intValue, isIndexed: indexed)
  }

  private func date(_ text: String?) -> Date? {
    guard let text else { return nil }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
  }
}
