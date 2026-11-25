import BridgeACP
import BridgeAgentCore
import BridgeMCP
import BridgeServiceCore
import Crypto
import Foundation

struct WorkbenchSearchCursor: Codable, Equatable {
  var version = 1
  var queryDigest: String
  var source: String
  var projectID: String?
  var turn = 0
  var workbenchAfterTime: Double?
  var workbenchAfterID: String?
  var workbenchCursor: String?
  var workbenchDone = false
  var bridgeOffset = 0
  var bridgeDone = false
  var agentProjectID: String?
  var agentInstallationID: String?
  var agentPairComplete = false
  var agentSessionOffset = 0
  var agentSessionID: String?
  var agentMessageOffset = 0
  var agentDone = false

  static func make(query: String, source: String, projectID: String?) -> Self {
    let digest = SHA256.hash(data: Data(query.utf8)).map { String(format: "%02x", $0) }.joined()
    return Self(queryDigest: digest, source: source, projectID: projectID)
  }

  static func decode(_ value: String, matching expected: Self) throws -> Self {
    guard value.utf8.count <= 8192, let data = Data(base64Encoded: value),
      let cursor = try? JSONDecoder().decode(Self.self, from: data), cursor.version == 1,
      cursor.queryDigest == expected.queryDigest, cursor.source == expected.source,
      cursor.projectID == expected.projectID, (0...1_000_000).contains(cursor.bridgeOffset),
      (0...1_000_000).contains(cursor.agentSessionOffset),
      (0...1_000_000).contains(cursor.agentMessageOffset), (0...2).contains(cursor.turn),
      (cursor.workbenchAfterTime == nil) == (cursor.workbenchAfterID == nil),
      (cursor.workbenchCursor?.utf8.count ?? 0) <= 4096
    else { throw ServiceStoreError.invalidArgument("workbench.search_cursor") }
    return cursor
  }

  func encoded() throws -> String {
    let value = try JSONEncoder().encode(self).base64EncodedString()
    guard value.utf8.count <= 8192 else {
      throw ServiceStoreError.invalidArgument("workbench.search_cursor")
    }
    return value
  }

  func includes(_ name: String) -> Bool { source == "all" || source == name }
  var hasMore: Bool {
    (includes("workbench") && !workbenchDone) || (includes("bridge") && !bridgeDone)
      || (includes("agent") && !agentDone)
  }
}

extension ServiceEmbeddedDSHController {
  func searchSessions(_ payload: [String: ACPJSONValue]) async throws -> ACPJSONValue {
    guard let rawQuery = payload["query"]?.stringValue else {
      throw ServiceStoreError.invalidArgument("workbench.search_query")
    }
    let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty, query.utf16.count <= 256, !query.contains("\0") else {
      throw ServiceStoreError.invalidArgument("workbench.search_query")
    }
    let limit = payload["limit"]?.intValue ?? 20
    guard (1...20).contains(limit), payload["limit"] == nil || payload["limit"]?.intValue != nil
    else {
      throw ServiceStoreError.invalidArgument("workbench.search_limit")
    }
    let source = payload["source"]?.stringValue ?? "all"
    guard source.utf8.count <= 64,
      payload["source"] == nil || payload["source"]?.stringValue != nil
    else {
      throw ServiceStoreError.invalidArgument("workbench.search_source")
    }
    if !["all", "workbench", "bridge", "agent"].contains(source) {
      return .object([
        "items": .array([]), "hasMore": .bool(false),
        "sourceStatus": .object([source: searchStatus("unsupported", scope: "unknown")]),
      ])
    }
    guard payload["projectID"] == nil || payload["projectID"]?.stringValue != nil else {
      throw ServiceStoreError.invalidArgument("workbench.search_project")
    }
    let projectID = payload["projectID"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
    if let projectID,
      try await projects.project(id: .init(rawValue: projectID)) == nil
    {
      throw ServiceStoreError.invalidArgument("workbench.search_project")
    }
    let expected = WorkbenchSearchCursor.make(query: query, source: source, projectID: projectID)
    var cursor = expected
    if let raw = payload["cursor"] {
      guard let value = raw.stringValue else {
        throw ServiceStoreError.invalidArgument("workbench.search_cursor")
      }
      cursor = try WorkbenchSearchCursor.decode(value, matching: expected)
    }
    let registered = try await projects.projects()
      .filter { projectID == nil || $0.id.rawValue == projectID }
      .sorted { $0.id.rawValue < $1.id.rawValue }
    let projectIDs = Set(registered.map { $0.id.rawValue })
    let available = registered.filter { (try? $0.root.validateCurrentIdentity()) != nil }
    let unavailableProjectIDs = projectIDs.subtracting(available.map { $0.id.rawValue })
    let names = ["workbench", "bridge", "agent"]
    let ordered = Array(names[cursor.turn...] + names[..<cursor.turn])
    let sources = ordered.filter {
      cursor.includes($0)
        && !($0 == "workbench"
          ? cursor.workbenchDone
          : $0 == "bridge" ? cursor.bridgeDone : cursor.agentDone)
    }
    cursor.turn = (cursor.turn + 1) % names.count
    var items: [ACPJSONValue] = []
    var statuses: [String: ACPJSONValue] = [:]
    for name in ["workbench", "bridge", "agent"] where !cursor.includes(name) {
      statuses[name] = searchStatus("excluded", scope: "messages")
    }
    for name in names where cursor.includes(name) && !sources.contains(name) {
      statuses[name] = searchStatus("ready", scope: "messages")
    }
    for (index, name) in sources.enumerated() {
      let count = limit / sources.count + (index < limit % sources.count ? 1 : 0)
      guard count > 0 else {
        statuses[name] = searchStatus("more", scope: "messages")
        continue
      }
      do {
        switch name {
        case "workbench":
          if !cursor.workbenchDone {
            items += try await searchWorkbench(
              query, projects: projectIDs, unavailableProjects: unavailableProjectIDs,
              cursor: &cursor, limit: count)
          }
          statuses[name] = searchStatus(cursor.workbenchDone ? "ready" : "more", scope: "messages")
        case "bridge":
          if !cursor.bridgeDone {
            items += try await searchBridge(
              query, projects: projectIDs, unavailableProjects: unavailableProjectIDs,
              cursor: &cursor, limit: count)
          }
          statuses[name] = searchStatus(cursor.bridgeDone ? "ready" : "more", scope: "messages")
        default:
          if cursor.agentDone {
            statuses[name] = searchStatus("ready", scope: "messages")
          } else {
            let result = try await searchAgent(
              query, projects: available.map { $0.id.rawValue }, cursor: &cursor)
            items += result.items
            statuses[name] = searchStatus(result.status, scope: "messages")
          }
        }
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        statuses[name] = searchStatus("unavailable", scope: "messages")
      }
    }
    var result: [String: ACPJSONValue] = [
      "items": .array(items), "hasMore": .bool(cursor.hasMore),
      "sourceStatus": .object(statuses),
    ]
    if cursor.hasMore { result["nextCursor"] = .string(try cursor.encoded()) }
    return .object(result)
  }

  private func searchWorkbench(
    _ query: String, projects: Set<String>, unavailableProjects: Set<String>,
    cursor: inout WorkbenchSearchCursor, limit: Int
  ) async throws -> [ACPJSONValue] {
    let before: ServiceWorkbenchConversationCursor?
    if let time = cursor.workbenchAfterTime, let id = cursor.workbenchAfterID {
      before = .init(updatedAt: Date(timeIntervalSince1970: time), logicalSessionID: id)
    } else {
      before = nil
    }
    let batch = try await store.workbenchConversations(limit: 500, before: before)
    let allowed = batch.filter { $0.projectID.map(projects.contains) ?? (cursor.projectID == nil) }
    let byNative = Dictionary(uniqueKeysWithValues: allowed.map { ($0.nativeSessionID, $0) })
    var search: [String: ACPJSONValue] = [
      "query": .string(query), "limit": .integer(Int64(limit)),
      "sessionIDs": .array(allowed.map { .string($0.nativeSessionID) }),
    ]
    if let value = cursor.workbenchCursor { search["cursor"] = .string(value) }
    let response: ACPJSONValue
    if allowed.isEmpty {
      response = .object([:])
    } else {
      response = try await invoke(action: "session.search", payload: .object(search))
    }
    var items: [ACPJSONValue] = []
    for row in response["items"]?.arrayValue ?? [] {
      guard let id = row["sessionId"]?.stringValue, let conversation = byNative[id],
        let seq = row["seq"]?.intValue, seq >= 0
      else { continue }
      nativeLogicalIDs[id] = conversation.logicalSessionID
      var result: [String: ACPJSONValue] = [
        "source": .string("workbench"),
        "sessionId": .string(conversation.logicalSessionID), "seq": .integer(Int64(seq)),
        "matchAnchor": .object(["seq": .integer(Int64(seq))]),
      ]
      if let projectID = conversation.projectID { result["projectID"] = .string(projectID) }
      if let projectID = conversation.projectID, unavailableProjects.contains(projectID) {
        result["projectStatus"] = .string("unavailable")
      }
      if let title = row["title"]?.stringValue { result["title"] = .string(title) }
      if let excerpt = row["excerpt"]?.stringValue { result["excerpt"] = .string(excerpt) }
      items.append(.object(result))
    }
    cursor.workbenchCursor = response["nextCursor"]?.stringValue
    if cursor.workbenchCursor == nil {
      if batch.count == 500, let last = batch.last {
        cursor.workbenchAfterTime = last.updatedAt.timeIntervalSince1970
        cursor.workbenchAfterID = last.logicalSessionID
      } else {
        cursor.workbenchDone = true
      }
    }
    return items
  }

  private func searchBridge(
    _ query: String, projects: Set<String>, unavailableProjects: Set<String>,
    cursor: inout WorkbenchSearchCursor, limit: Int
  ) async throws -> [ACPJSONValue] {
    let tasks = try await store.searchWorkbenchTasks(
      query: query, projectID: cursor.projectID, limit: limit, offset: cursor.bridgeOffset)
    cursor.bridgeOffset = min(cursor.bridgeOffset + tasks.count, 1_000_000)
    cursor.bridgeDone = tasks.count < limit || cursor.bridgeOffset == 1_000_000
    return tasks.filter { projects.contains($0.projectID) }.map { task in
      var item: [String: ACPJSONValue] = [
        "source": .string("bridge"), "projectID": .string(task.projectID),
        "taskID": .string(task.taskID), "providerID": .string(task.providerID),
        "title": .string(task.title), "excerpt": .string(task.excerpt),
      ]
      if let messageID = task.messageID, let messageKey = task.messageKey {
        item["matchAnchor"] = .object([
          "messageID": .integer(messageID), "messageKey": .string(messageKey),
        ])
      } else {
        item["matchAnchor"] = .object(["type": .string("prompt")])
      }
      if unavailableProjects.contains(task.projectID) {
        item["projectStatus"] = .string("unavailable")
      }
      return .object(item)
    }
  }

  private func searchAgent(
    _ query: String, projects: [String], cursor: inout WorkbenchSearchCursor
  ) async throws -> (items: [ACPJSONValue], status: String) {
    let installations = try await store.agentInstallations().filter(\.isEnabled)
      .sorted { $0.id.rawValue < $1.id.rawValue }
    guard let pair = nextSearchPair(projects, installations: installations, cursor: cursor) else {
      cursor.agentDone = true
      return ([], "ready")
    }
    if pair.projectID != cursor.agentProjectID || pair.installationID != cursor.agentInstallationID
    {
      cursor.agentProjectID = pair.projectID
      cursor.agentInstallationID = pair.installationID
      cursor.agentPairComplete = false
      cursor.agentSessionOffset = 0
      cursor.agentSessionID = nil
      cursor.agentMessageOffset = 0
    }
    let directory = MCPNativeSessionDirectoryRequest(
      operation: .list, projectID: pair.projectID, installationID: pair.installationID,
      offset: cursor.agentSessionOffset, limit: 1)
    let page: AgentNativeSessionPage
    do {
      guard
        let result = try await application.serviceNativeSessionDirectory(
          directory, deadline: .now.advanced(by: .seconds(15))
        ).page
      else { throw BridgeMCPQueryError.unavailable }
      page = result
    } catch BridgeMCPQueryError.nativeSessionDirectory(.unsupported) {
      advanceSearchPair(projects, installations: installations, cursor: &cursor)
      return ([], "unsupported")
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      advanceSearchPair(projects, installations: installations, cursor: &cursor)
      return ([], "unavailable")
    }
    guard let session = page.sessions.first else {
      advanceSearchPair(projects, installations: installations, cursor: &cursor)
      return ([], cursor.agentDone ? "ready" : "more")
    }
    if cursor.agentSessionID != session.sessionID {
      cursor.agentSessionID = session.sessionID
      cursor.agentMessageOffset = 0
    }
    if cursor.agentMessageOffset == 0,
      session.title.localizedCaseInsensitiveContains(query)
        || (session.firstPrompt?.localizedCaseInsensitiveContains(query) ?? false)
    {
      let result = agentSearchItem(
        pair, session: session, excerpt: session.firstPrompt ?? session.title,
        anchor: .object(["pageOffset": .integer(0)]))
      advanceSearchSession(page, projects: projects, installations: installations, cursor: &cursor)
      return ([result], cursor.agentDone ? "ready" : "more")
    }
    let request = MCPNativeSessionDirectoryRequest(
      operation: .read, projectID: pair.projectID, installationID: pair.installationID,
      sessionID: session.sessionID, offset: cursor.agentMessageOffset, limit: 20)
    do {
      guard
        let transcript = try await application.serviceNativeSessionDirectory(
          request, deadline: .now.advanced(by: .seconds(15))
        ).transcript
      else { throw BridgeMCPQueryError.unavailable }
      if let message = transcript.messages.first(where: {
        $0.content.localizedCaseInsensitiveContains(query)
      }) {
        let anchor: ACPJSONValue = .object([
          "messageID": .string(message.messageID),
          "pageOffset": .integer(Int64(cursor.agentMessageOffset)),
        ])
        let result = agentSearchItem(
          pair, session: session, excerpt: message.content, anchor: anchor)
        advanceSearchSession(
          page, projects: projects, installations: installations, cursor: &cursor)
        return ([result], cursor.agentDone ? "ready" : "more")
      }
      if let next = transcript.nextOffset, next > cursor.agentMessageOffset, next <= 1_000_000 {
        cursor.agentMessageOffset = next
      } else {
        advanceSearchSession(
          page, projects: projects, installations: installations, cursor: &cursor)
      }
      return ([], cursor.agentDone ? "ready" : "more")
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      advanceSearchSession(page, projects: projects, installations: installations, cursor: &cursor)
      return ([], "unavailable")
    }
  }

  private func agentSearchItem(
    _ pair: (projectID: String, installationID: String, providerID: String),
    session: AgentNativeSessionSummary, excerpt: String, anchor: ACPJSONValue
  ) -> ACPJSONValue {
    .object([
      "source": .string("agent"), "projectID": .string(pair.projectID),
      "installationID": .string(pair.installationID), "providerID": .string(pair.providerID),
      "nativeSessionID": .string(session.sessionID), "title": .string(session.title),
      "excerpt": .string(String(excerpt.prefix(240))), "matchAnchor": anchor,
    ])
  }

  private func advanceSearchSession(
    _ page: AgentNativeSessionPage, projects: [String],
    installations: [ServiceAgentInstallationRecord],
    cursor: inout WorkbenchSearchCursor
  ) {
    cursor.agentMessageOffset = 0
    cursor.agentSessionID = nil
    if let next = page.nextOffset, next > cursor.agentSessionOffset, next <= 1_000_000 {
      cursor.agentSessionOffset = next
    } else {
      advanceSearchPair(projects, installations: installations, cursor: &cursor)
    }
  }

  private func advanceSearchPair(
    _ projects: [String], installations: [ServiceAgentInstallationRecord],
    cursor: inout WorkbenchSearchCursor
  ) {
    cursor.agentPairComplete = true
    cursor.agentSessionOffset = 0
    cursor.agentSessionID = nil
    cursor.agentMessageOffset = 0
    cursor.agentDone = nextSearchPair(projects, installations: installations, cursor: cursor) == nil
  }

  private func nextSearchPair(
    _ projects: [String], installations: [ServiceAgentInstallationRecord],
    cursor: WorkbenchSearchCursor
  ) -> (projectID: String, installationID: String, providerID: String)? {
    for project in projects {
      if let previous = cursor.agentProjectID, project < previous { continue }
      for installation in installations {
        let id = installation.id.rawValue
        if project == cursor.agentProjectID, let previous = cursor.agentInstallationID,
          id < previous || (id == previous && cursor.agentPairComplete)
        {
          continue
        }
        return (project, id, installation.providerID.rawValue)
      }
    }
    return nil
  }

  private func searchStatus(_ state: String, scope: String) -> ACPJSONValue {
    .object(["state": .string(state), "scope": .string(scope)])
  }
}
