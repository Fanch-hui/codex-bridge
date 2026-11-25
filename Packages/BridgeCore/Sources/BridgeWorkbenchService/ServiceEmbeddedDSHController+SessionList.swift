import BridgeACP
import BridgeServiceCore
import Foundation

extension ServiceEmbeddedDSHController {
  private struct ListedSession {
    let row: [String: ACPJSONValue]
    let sessionID: String
    let conversation: ServiceWorkbenchConversation
    let projectID: String?
  }

  /// Store state is read in batches (conversations and bindings before the pass, lifecycle states
  /// after it), so the cost no longer grows with three queries per listed session.
  func listSessions(_ payload: [String: ACPJSONValue]) async throws -> ACPJSONValue {
    let result = try await invoke(action: "session.list", payload: .object(payload))
    let requestedProjectID = payload["projectID"]?.stringValue
    let registered = try await projects.projects()
    var rows: [(row: [String: ACPJSONValue], sessionID: String)] = []
    for item in result["items"]?.arrayValue ?? [] {
      guard let row = item.objectValue, let sessionID = row["sessionId"]?.stringValue else {
        continue
      }
      rows.append((row: row, sessionID: sessionID))
    }
    var conversations = try await store.workbenchConversations(
      nativeSessionIDs: rows.map { $0.sessionID })
    let unresolvedIDs = rows.map { $0.sessionID }.filter {
      conversations[$0] == nil && sessionProjects[$0] == nil
    }
    let legacyBindings = try await storedValues(for: unresolvedIDs, key: Self.sessionKey)

    var listed: [ListedSession] = []
    for entry in rows {
      let sessionID = entry.sessionID
      var conversation = conversations[sessionID]
      var projectID = conversation?.projectID
      if projectID == nil {
        if let cached = sessionProjects[sessionID] {
          projectID = cached
        } else {
          projectID = try await resolveStoredProjectID(
            for: sessionID, conversation: conversation, legacyBinding: legacyBindings[sessionID])
        }
      }
      if projectID == nil, let cwd = entry.row["cwd"]?.stringValue,
        let project = registered.first(where: { Self.samePath($0.root.canonicalPath, cwd) })
      {
        try project.root.validateCurrentIdentity()
        try await bindSession(sessionID, projectID: project.id.rawValue)
        projectID = project.id.rawValue
      }
      if conversation == nil, let projectID {
        conversation = try await store.createWorkbenchConversation(
          logicalSessionID: sessionID,
          nativeSessionID: sessionID, projectID: projectID)
        conversations[sessionID] = conversation
        noteConversationWrite()
      }
      guard let conversation, conversation.nativeSessionID == sessionID,
        requestedProjectID == nil || requestedProjectID == projectID
      else { continue }
      listed.append(
        ListedSession(
          row: entry.row, sessionID: sessionID, conversation: conversation, projectID: projectID))
    }

    let lifecycleStates = try await storedValues(
      for: listed.map { $0.conversation.logicalSessionID }, key: Self.sessionStateKey)
    var items: [ACPJSONValue] = []
    for session in listed {
      let logicalID = session.conversation.logicalSessionID
      let lifecycleState = lifecycleStates[logicalID]
      if lifecycleState == "deleted" { continue }
      nativeLogicalIDs[session.sessionID] = logicalID
      var row = session.row
      row.removeValue(forKey: "cwd")
      row["sessionId"] = .string(logicalID)
      row["nativeSessionId"] = .string(session.sessionID)
      row["projectID"] = session.projectID.map(ACPJSONValue.string) ?? .null
      row["scope"] = .string(session.projectID == nil ? "chatOnly" : "project")
      row["archived"] = .bool(lifecycleState == "archived")
      items.append(.object(row))
    }
    var response = result.objectValue ?? [:]
    response["items"] = .array(items)
    return .object(response)
  }

  /// Reads the setting stored under `key(id)` for every ID in one query; IDs without one are absent.
  private func storedValues(
    for ids: [String], key: (String) -> String
  ) async throws -> [String: String] {
    let unique = Array(Set(ids))
    let settingKeys = unique.map(key)
    let records = try await store.settingRecords(keys: settingKeys)
    var values: [String: String] = [:]
    for (id, settingKey) in zip(unique, settingKeys) {
      if let record = records[settingKey] { values[id] = record.value }
    }
    return values
  }
}
