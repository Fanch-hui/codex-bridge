import BridgeACP
import BridgeAgentCore
import BridgeSecurity
import Foundation

public struct QoderNativeSessionDirectoryManager: AgentNativeSessionDirectoryManaging, Sendable {
  private let configuration: QoderSDKProviderConfiguration

  public init(configuration: QoderSDKProviderConfiguration) {
    self.configuration = configuration
  }

  public func listNativeSessions(
    scope: AgentNativeSessionDirectoryScope,
    installation: AgentInstallation,
    page: AgentNativeSessionPageRequest
  ) async throws -> AgentNativeSessionPage {
    let context = try await context(scope: scope, installation: installation)
    let value = try await request("list", scope: scope, context: context, page: page)
    guard let records = value["sessions"]?.arrayValue else {
      throw AgentNativeSessionDirectoryError.runtimeFailure
    }
    let sessions = try records.compactMap { record -> AgentNativeSessionSummary? in
      guard let record = record.objectValue else { return nil }
      let sessionID = try requiredString("sessionID", in: record)
      let state = try context.store.indexState(
        binding(
          sessionID: sessionID, scope: scope, distribution: context.profile.distribution,
          accountScope: context.accountScope))
      guard state == .missing || state == .current else { return nil }
      return try summary(record, isIndexed: state == .current)
    }
    return AgentNativeSessionPage(sessions: sessions, nextOffset: value["nextOffset"]?.intValue)
  }

  public func readNativeSession(
    sessionID: String,
    scope: AgentNativeSessionDirectoryScope,
    installation: AgentInstallation,
    page: AgentNativeSessionPageRequest
  ) async throws -> AgentNativeSessionTranscriptPage {
    let context = try await context(scope: scope, installation: installation)
    try requireCurrentOrMissingIndex(sessionID: sessionID, scope: scope, context: context)
    let value = try await request(
      "read", scope: scope, context: context, page: page, sessionID: sessionID)
    guard value["sessionID"]?.stringValue == sessionID,
      let values = value["messages"]?.arrayValue
    else { throw AgentNativeSessionDirectoryError.scopeMismatch }
    let messages = try values.compactMap { item -> AgentNativeSessionMessage? in
      guard let item = item.objectValue else { return nil }
      return try AgentNativeSessionMessage(
        messageID: requiredString("messageID", in: item),
        role: requiredString("role", in: item),
        content: requiredString("content", in: item),
        createdAt: parseDate(item["createdAt"]?.stringValue))
    }
    return AgentNativeSessionTranscriptPage(
      sessionID: sessionID, messages: messages, nextOffset: value["nextOffset"]?.intValue)
  }

  public func renameNativeSession(
    sessionID: String,
    title: String,
    scope: AgentNativeSessionDirectoryScope,
    installation: AgentInstallation
  ) async throws -> AgentNativeSessionSummary {
    let context = try await context(scope: scope, installation: installation)
    try requireCurrentOrMissingIndex(sessionID: sessionID, scope: scope, context: context)
    let value = try await request(
      "rename", scope: scope, context: context, sessionID: sessionID, title: title)
    let indexed = try context.store.containsIndex(
      binding(
        sessionID: sessionID, scope: scope, distribution: context.profile.distribution,
        accountScope: context.accountScope))
    return try summary(value.objectValue ?? [:], isIndexed: indexed)
  }

  public func deleteNativeSession(
    sessionID: String,
    scope: AgentNativeSessionDirectoryScope,
    installation: AgentInstallation
  ) async throws {
    let context = try await context(scope: scope, installation: installation)
    try requireCurrentOrMissingIndex(sessionID: sessionID, scope: scope, context: context)
    _ = try await request("delete", scope: scope, context: context, sessionID: sessionID)
    try context.store.removeIndex(
      binding(
        sessionID: sessionID, scope: scope, distribution: context.profile.distribution,
        accountScope: context.accountScope))
  }

  public func indexNativeSession(
    sessionID: String,
    scope: AgentNativeSessionDirectoryScope,
    installation: AgentInstallation
  ) async throws -> AgentNativeSessionIndexReceipt {
    let context = try await context(scope: scope, installation: installation)
    try requireCurrentOrMissingIndex(sessionID: sessionID, scope: scope, context: context)
    _ = try await request("verify", scope: scope, context: context, sessionID: sessionID)
    let binding = binding(
      sessionID: sessionID, scope: scope, distribution: context.profile.distribution,
      accountScope: context.accountScope)
    try context.store.save(binding)
    return AgentNativeSessionIndexReceipt(scope: scope, sessionID: sessionID)
  }

  public func isIndexedNativeSession(
    sessionID: String,
    scope: AgentNativeSessionDirectoryScope,
    installation: AgentInstallation
  ) async throws -> Bool {
    let context = try await context(scope: scope, installation: installation)
    let binding = binding(
      sessionID: sessionID, scope: scope, distribution: context.profile.distribution,
      accountScope: context.accountScope)
    guard try context.store.indexState(binding) == .current else { return false }
    _ = try await request("verify", scope: scope, context: context, sessionID: sessionID)
    return true
  }

  private func requireCurrentOrMissingIndex(
    sessionID: String,
    scope: AgentNativeSessionDirectoryScope,
    context: (
      profile: QoderRuntimeProfile,
      store: QoderSessionStore,
      projectRoot: String,
      accountScope: String,
      client: QoderSDKClient
    )
  ) throws {
    do {
      try context.store.requireCurrentOrMissing(
        binding(
          sessionID: sessionID, scope: scope, distribution: context.profile.distribution,
          accountScope: context.accountScope))
    } catch {
      throw AgentNativeSessionDirectoryError.scopeMismatch
    }
  }

  private func context(scope: AgentNativeSessionDirectoryScope, installation: AgentInstallation)
    async throws
    -> (
      profile: QoderRuntimeProfile,
      store: QoderSessionStore,
      projectRoot: String,
      accountScope: String,
      client: QoderSDKClient
    )
  {
    guard scope.providerID == .qoder, scope.installationID == installation.id,
      installation.providerID == .qoder
    else { throw AgentNativeSessionDirectoryError.scopeMismatch }
    let profile = try await QoderRuntimeProfile.make(
      installation: installation, configuration: configuration)
    guard scope.region == profile.distribution.rawValue else {
      throw AgentNativeSessionDirectoryError.scopeMismatch
    }
    let projectRoot = try RegisteredRoot(capturing: URL(fileURLWithPath: scope.projectRoot))
      .canonicalPath
    guard AgentPathSemantics.isContained(projectRoot, in: scope.projectRoot),
      AgentPathSemantics.isContained(scope.projectRoot, in: projectRoot)
    else { throw AgentNativeSessionDirectoryError.scopeMismatch }
    let store = try QoderSessionStore(directory: configuration.runtimeBaseDirectory)
    let client = try profile.client(cwd: projectRoot, factory: configuration.transportFactory)
    let parameters = profile.parameters(
      cwd: projectRoot, sessionID: UUID().uuidString.lowercased(), request: nil,
      resources: .init(), proxy: configuration.proxy)
    let accountScope: String
    do {
      let response = try await client.request("qoder/account_scope", params: parameters)
      let digest = try requiredString("digest", in: response.objectValue ?? [:])
      guard digest.count == 64,
        digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
      else { throw AgentNativeSessionDirectoryError.runtimeFailure }
      accountScope = digest
    } catch let error as AgentNativeSessionDirectoryError {
      await client.shutdown()
      throw error
    } catch {
      await client.shutdown()
      throw AgentNativeSessionDirectoryError.runtimeFailure
    }
    return (profile, store, projectRoot, accountScope, client)
  }

  private func request(
    _ operation: String,
    scope: AgentNativeSessionDirectoryScope,
    context: (
      profile: QoderRuntimeProfile,
      store: QoderSessionStore,
      projectRoot: String,
      accountScope: String,
      client: QoderSDKClient
    ),
    page: AgentNativeSessionPageRequest? = nil,
    sessionID: String? = nil,
    title: String? = nil
  ) async throws -> QoderJSONValue {
    var params =
      context.profile.parameters(
        cwd: context.projectRoot, sessionID: UUID().uuidString.lowercased(), request: nil,
        resources: .init(), proxy: configuration.proxy,
        expectedAccountScope: context.accountScope
      ).objectValue ?? [:]
    params["operation"] = .string(operation)
    if let page {
      params["offset"] = .integer(Int64(page.offset))
      params["limit"] = .integer(Int64(page.limit))
    }
    if let sessionID { params["sessionID"] = .string(sessionID) }
    if let title { params["title"] = .string(title) }
    do {
      let result = try await context.client.request("qoder/native_history", params: .object(params))
      await context.client.shutdown()
      return result
    } catch {
      await context.client.shutdown()
      throw AgentNativeSessionDirectoryError.runtimeFailure
    }
  }

  private func binding(
    sessionID: String,
    scope: AgentNativeSessionDirectoryScope,
    distribution: QoderDistribution,
    accountScope: String
  ) -> QoderSessionBinding {
    QoderSessionBinding(
      sessionID: sessionID, distribution: distribution,
      installationID: scope.installationID.rawValue, projectID: scope.projectID,
      projectRoot: scope.projectRoot, accountScope: accountScope)
  }

  private func summary(_ value: [String: QoderJSONValue], isIndexed: Bool) throws
    -> AgentNativeSessionSummary
  {
    try AgentNativeSessionSummary(
      sessionID: requiredString("sessionID", in: value),
      title: requiredString("title", in: value),
      firstPrompt: value["firstPrompt"]?.stringValue,
      createdAt: parseDate(value["createdAt"]?.stringValue),
      updatedAt: parseDate(value["updatedAt"]?.stringValue),
      messageCount: value["messageCount"]?.intValue,
      isIndexed: isIndexed)
  }

  private func requiredString(_ key: String, in value: [String: QoderJSONValue]) throws -> String {
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
