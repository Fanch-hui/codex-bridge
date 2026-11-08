import BridgeACP
import BridgeAgentCore
import BridgeDomain
import BridgeSecurity
import BridgeServiceApplication
import BridgeServiceCore
import Crypto
import Foundation

extension ServiceEmbeddedDSHController {
  func performPrompt(_ input: [String: ACPJSONValue]) async throws -> ACPJSONValue {
    let prepared: [String: ACPJSONValue]
    do {
      let id = try Self.requiredString(input, "sessionId")
      try await authorizeSession(id, requiresProject: false)
      prepared = try await preparePrompt(input, sessionID: id)
      try await synchronizeSessionScope(id)
    } catch {
      throw WorkbenchTaskOperationNotDispatched(cause: error)
    }
    return try await invoke(action: "session.prompt", payload: .object(prepared))
  }

  func createSession(_ input: [String: ACPJSONValue]) async throws -> ACPJSONValue {
    let projectID = input["projectID"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
    let sessionID = input["sessionId"]?.stringValue ?? UUID().uuidString
    if let existing = try await store.workbenchConversation(logicalSessionID: sessionID),
      existing.projectID != projectID
    {
      throw ServiceStoreError.invalidArgument("workbench.session_scope")
    }
    var payload = input
    payload["sessionId"] = .string(sessionID)
    payload["contextSessionId"] = .string(sessionID)
    if let projectID {
      let project = try await registeredProject(projectID)
      payload["cwd"] = .string(project.root.canonicalPath)
      payload["scope"] = .string("project")
    } else {
      let directory = dataRoot.appendingPathComponent("WorkbenchChat", isDirectory: true)
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      let root = try RegisteredRoot(capturing: directory)
      payload["cwd"] = .string(root.canonicalPath)
      payload["scope"] = .string("chatOnly")
    }
    payload.removeValue(forKey: "projectID")
    _ = try await store.createWorkbenchConversation(
      logicalSessionID: sessionID,
      nativeSessionID: sessionID, projectID: projectID)
    noteConversationWrite()
    nativeLogicalIDs[sessionID] = sessionID
    let result = try await invoke(action: "session.create", payload: .object(payload))
    guard result["sessionId"]?.stringValue == sessionID else {
      throw ServiceStoreError.invalidArgument("embedded_dsh.session_response")
    }
    if let projectID { try await bindSession(sessionID, projectID: projectID) }
    var response = result.objectValue ?? [:]
    response["scope"] = .string(projectID == nil ? "chatOnly" : "project")
    response["projectID"] = projectID.map(ACPJSONValue.string) ?? .null
    return .object(response)
  }

  func project(for sessionID: String) async throws -> ServiceProjectRecord {
    guard let projectID = try await storedProjectID(for: sessionID) else {
      throw ServiceStoreError.invalidArgument("embedded_dsh.session")
    }
    return try await registeredProject(projectID)
  }

  func registeredProject(_ projectID: String) async throws -> ServiceProjectRecord {
    guard let project = try await projects.project(id: ProjectID(rawValue: projectID)) else {
      throw ServiceStoreError.unknownProject(ProjectID(rawValue: projectID))
    }
    try project.root.validateCurrentIdentity()
    return project
  }

  func storedProjectID(for sessionID: String) async throws -> String? {
    if let projectID = sessionProjects[sessionID] { return projectID }
    let conversation = try await store.workbenchConversation(nativeSessionID: sessionID)
    var legacyBinding: String?
    if conversation == nil {
      legacyBinding = try await store.setting(key: Self.sessionKey(sessionID))?.value
    }
    return try await resolveStoredProjectID(
      for: sessionID, conversation: conversation, legacyBinding: legacyBinding)
  }

  /// Resolves the project from already-read store state (`sessionProjects` is not consulted).
  /// `legacyBinding` is the per-session binding setting, only meaningful without a conversation.
  func resolveStoredProjectID(
    for sessionID: String, conversation: ServiceWorkbenchConversation?, legacyBinding: String?
  ) async throws -> String? {
    if let conversation {
      if conversation.nativeSessionID == sessionID {
        if let projectID = conversation.projectID { sessionProjects[sessionID] = projectID }
        return conversation.projectID
      }
      let segments = try await store.workbenchSegments(
        logicalSessionID: conversation.logicalSessionID)
      return segments.first(where: { $0.nativeSessionID == sessionID })?.projectID
    }
    guard let legacyBinding else { return nil }
    sessionProjects[sessionID] = legacyBinding
    return legacyBinding
  }

  func bindSession(_ sessionID: String, projectID: String) async throws {
    if let previous = try await storedProjectID(for: sessionID), previous != projectID {
      throw ServiceStoreError.invalidArgument("embedded_dsh.session_project")
    }
    try await store.setSetting(
      ServiceSettingRecord(key: Self.sessionKey(sessionID), value: projectID, updatedAt: Date()))
    sessionProjects[sessionID] = projectID
  }

  func bindNativeChildren(_ response: ACPJSONValue, rootID: String) async throws {
    guard let projectID = try await storedProjectID(for: rootID) else { return }
    let rows = response["items"]?.arrayValue ?? response["agents"]?.arrayValue ?? []
    for row in rows {
      guard let sessionID = row["sessionId"]?.stringValue ?? row["childSessionId"]?.stringValue,
        sessionID != rootID
      else { continue }
      try await bindSession(sessionID, projectID: projectID)
    }
  }

  func enrichSubagentList(_ response: ACPJSONValue, rootID: String) async throws -> ACPJSONValue {
    let bindings = (try? await application.embeddedDSHSubagents(parentSessionID: rootID)) ?? []
    guard !bindings.isEmpty, var root = response.objectValue else { return response }
    let byChildID = Dictionary(uniqueKeysWithValues: bindings.map { ($0.childID, $0) })
    var items: [ACPJSONValue] = []
    for element in root["items"]?.arrayValue ?? [] {
      guard var row = element.objectValue,
        let childID = row["childId"]?.stringValue ?? row["id"]?.stringValue,
        let binding = byChildID[childID]
      else {
        items.append(element)
        continue
      }
      row["mode"] = .string("external")
      row["workspaceMode"] = .string(try await workspaceMode(rootID: rootID, childID: childID))
      if let reason = try await workspaceReason(rootID: rootID, childID: childID) {
        row["workspaceReason"] = .string(reason)
      }
      if let status = binding.currentStatus {
        row["status"] = .string(status.rawValue)
      }
      row["provider"] = .string(binding.providerID)
      if let taskID = binding.currentTaskID {
        row["taskID"] = .string(taskID.rawValue)
      }
      if let installationID = binding.installationID {
        row["installationID"] = .string(installationID)
      }
      items.append(.object(row))
    }
    root["items"] = .array(items)
    return .object(root)
  }

  static func sessionKey(_ sessionID: String) -> String {
    "embedded_dsh.session."
      + SHA256.hash(data: Data(sessionID.utf8))
      .map { String(format: "%02x", $0) }.joined()
  }

  static func sessionStateKey(_ sessionID: String) -> String {
    "embedded_dsh.session_state."
      + SHA256.hash(data: Data(sessionID.utf8))
      .map { String(format: "%02x", $0) }.joined()
  }

  func archiveSession(_ payload: [String: ACPJSONValue], archived: Bool) async throws
    -> ACPJSONValue
  {
    let sessionID = try Self.requiredString(payload, "sessionId")
    try await authorizeSession(sessionID, requiresProject: false)
    if archived {
      _ = try? await stopSession(["sessionId": .string(sessionID)])
    }
    try await store.setSetting(
      ServiceSettingRecord(
        key: Self.sessionStateKey(sessionID),
        value: archived ? "archived" : "active",
        updatedAt: Date()))
    return .object(["sessionId": .string(sessionID), "archived": .bool(archived)])
  }

  func deleteSession(_ payload: [String: ACPJSONValue]) async throws -> ACPJSONValue {
    let sessionID = try Self.requiredString(payload, "sessionId")
    try await authorizeSession(sessionID, requiresProject: false)
    _ = try? await stopSession(["sessionId": .string(sessionID)])
    try await store.setSetting(
      ServiceSettingRecord(
        key: Self.sessionStateKey(sessionID),
        value: "deleted",
        updatedAt: Date()))
    return .object(["sessionId": .string(sessionID), "deleted": .bool(true)])
  }

  static func samePath(_ lhs: String, _ rhs: String) -> Bool {
    let first = URL(fileURLWithPath: lhs).standardizedFileURL.path
    let second = URL(fileURLWithPath: rhs).standardizedFileURL.path
    #if os(Windows)
      return first.caseInsensitiveCompare(second) == .orderedSame
    #else
      return first == second
    #endif
  }

  func preparePrompt(_ input: [String: ACPJSONValue], sessionID: String) async throws
    -> [String: ACPJSONValue]
  {
    var result = input
    result.removeValue(forKey: "cwd")
    if try await storedProjectID(for: sessionID) != nil { _ = try await project(for: sessionID) }
    let references = input["attachmentRefs"]?.arrayValue ?? []
    let paths = input["attachmentPaths"]?.arrayValue ?? []
    guard paths.allSatisfy({ $0.stringValue != nil }) else {
      throw ServiceStoreError.invalidArgument("embedded_dsh.attachments")
    }
    var images: [SecureProjectImageData] = []
    if !paths.isEmpty {
      let project = try await project(for: sessionID)
      let root = try RegisteredRoot(capturing: URL(fileURLWithPath: project.root.canonicalPath))
      images = try SecureProjectImageReader.capture(
        relativePaths: paths.compactMap(\.stringValue), through: root)
    }
    var content: [ACPJSONValue] = []
    if let text = input["text"]?.stringValue, !text.isEmpty {
      content.append(.object(["type": .string("text"), "text": .string(text)]))
    }
    content += images.map { image in
      .object([
        "type": .string("image"), "mediaType": .string(image.attachment.mimeType),
        "data": .string(image.data.base64EncodedString()),
      ])
    }
    content += try attachmentContent(references)
    if !content.isEmpty { result["content"] = .array(content) }
    result.removeValue(forKey: "attachmentPaths")
    result.removeValue(forKey: "attachmentRefs")
    return result
  }
}
