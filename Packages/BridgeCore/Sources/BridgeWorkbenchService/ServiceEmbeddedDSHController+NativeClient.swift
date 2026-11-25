import BridgeACP
import BridgeEmbeddedDSH
import BridgeIPC
import BridgeServiceCore
import Foundation

struct NativeClientScope: Equatable, Sendable {
  let sessionIDs: [String]
  let workspacePaths: [String]

  var value: ACPJSONValue {
    .object([
      "sessionIDs": .array(sessionIDs.map { .string($0) }),
      "workspacePaths": .array(workspacePaths.map { .string($0) }),
    ])
  }
}

struct NativeClientStream: Sendable {
  let sessionIDs: [String]
}

extension ServiceEmbeddedDSHController {
  private static let nativeAuxiliaryEndpoints: Set<String> = [
    "session/list", "session/search", "session/page", "session/projections", "session/attachment",
    "session/modelCatalog", "skills/list", "commands/list", "fileReferences/list",
    "llm/listProviders",
    "llm/listConfigurableProviders", "pluginInventory/list", "pluginManager/listBundles",
    "pluginManager/listPlugins", "pluginManager/registries", "pluginManager/listVersionExemptions",
    "permissionPresets/catalog", "settings/describe", "settings/mutate", "settings/update",
    "settings/replace", "settings/openSettingsDocument", "credentials/describe", "credentials/set",
    "credentials/unset", "dynamicCordisRunner/inventory", "dynamicCordisRunner/syncInspectManifest",
  ]
  private static let nativeManagerEndpoints: Set<String> = [
    "pluginManager/inspect", "pluginManager/installBundle", "pluginManager/waitForInstall",
    "pluginManager/cancelInstall", "pluginManager/setBundleEnabled",
    "pluginManager/setPluginEnabled", "pluginManager/removeBundle",
    "pluginManager/setVersionExemption",
  ]
  static let nativePluginMutationEndpoints: Set<String> = [
    "pluginManager/installBundle", "pluginManager/setBundleEnabled",
    "pluginManager/setPluginEnabled",
    "pluginManager/removeBundle", "pluginManager/setVersionExemption",
  ]
  private static let nativeStreamEndpoints: Set<String> = [
    "$events", "session/control", "session/follow", "workspace/follow", "remoteAccess/follow",
    "job/list", "job/follow",
  ]
  private static let nativeWriteActions: [String: String] = [
    "session/prompt": "session.prompt", "session/cancel": "session.stop",
    "session/fork": "session.fork", "session/rename": "session.rename",
    "session/selectModel": "session.selectModel",
  ]
  private static let nativeWorkspaceActions: Set<String> = [
    "workspace/pinSession", "workspace/unpinSession", "workspace/archiveSession",
    "workspace/unarchiveSession",
  ]

  func resetNativeClient() {
    nativeClientEpoch += 1
    nativeClientIndexed = false
    nativeClientScope = nil
    loadedConversationMappings = nil
    nativeScopeMemo = nil
    nativeClientStreams.removeAll()
  }

  func nativeClient(action: String, payload: [String: ACPJSONValue]) async throws -> ACPJSONValue {
    if action == "client.rpc", let endpoint = payload["endpoint"]?.stringValue,
      Self.nativeManagerEndpoints.contains(endpoint)
    {
      return try await nativeManagerRPC(payload)
    }
    await nativeClientGate.acquire()
    defer { nativeClientGate.release() }
    guard !isShuttingDown else { throw CancellationError() }
    let epoch = nativeClientEpoch
    switch action {
    case "client.graph", "client.bundle", "client.rpc", "client.stream.open",
      "client.stream.send", "client.stream.close", "client.stream.poll":
      break
    default: throw ServiceStoreError.invalidArgument("embedded_dsh.client_action")
    }
    if action == "client.graph", !nativeClientIndexed {
      _ = try await listSessions([:])
      guard epoch == nativeClientEpoch, !isShuttingDown else { throw CancellationError() }
      nativeClientIndexed = true
    }
    if action == "client.rpc" {
      return try await nativeRPC(payload, epoch: epoch)
    }
    if action == "client.stream.open" {
      return try await openNativeStream(payload, epoch: epoch)
    }
    if action == "client.stream.send" || action == "client.stream.close" {
      let id = try Self.nativeStreamID(payload)
      guard let stream = nativeClientStreams[id] else {
        if action == "client.stream.close" { return .object([:]) }
        throw ServiceStoreError.invalidArgument("embedded_dsh.client_stream")
      }
      for sessionID in stream.sessionIDs {
        try await authorizeSession(sessionID, requiresProject: false)
      }
      if action == "client.stream.send", payload["type"]?.stringValue != "end" {
        throw ServiceStoreError.invalidArgument("embedded_dsh.client_uplink")
      }
      let result = try await invokeNative(action: action, payload: payload, epoch: epoch)
      if action == "client.stream.close" { nativeClientStreams.removeValue(forKey: id) }
      return result
    }
    return try await invokeNative(action: action, payload: payload, epoch: epoch)
  }

  private func nativeManagerRPC(_ payload: [String: ACPJSONValue]) async throws -> ACPJSONValue {
    guard !isShuttingDown, payload["channel"]?.stringValue == "/api" else {
      throw ServiceStoreError.invalidArgument("embedded_dsh.client_channel")
    }
    let epoch = nativeClientEpoch
    var trusted = payload
    trusted["scope"] = .object(["globalOnly": .bool(true)])
    if Self.nativePluginMutationEndpoints.contains(payload["endpoint"]?.stringValue ?? "") {
      let input = trusted
      let result = try await withNativePluginMaintenance(
        prepare: {
          _ = try await self.invoke(action: "status", payload: .object([:]))
        },
        operation: {
          // Keep the response attached to the service-owned task through installation and activation.
          return try await self.invokeNativePlugin(epoch: epoch, payload: .object(input))
        })
      guard epoch == nativeClientEpoch, !isShuttingDown else { throw CancellationError() }
      return result
    }
    let result = try await invoke(action: "client.rpc", payload: .object(trusted))
    guard epoch == nativeClientEpoch, !isShuttingDown else { throw CancellationError() }
    return result
  }

  private func nativeRPC(_ input: [String: ACPJSONValue], epoch: Int) async throws -> ACPJSONValue {
    var payload = input
    guard payload["channel"]?.stringValue == "/api" else {
      throw ServiceStoreError.invalidArgument("embedded_dsh.client_channel")
    }
    let endpoint = try Self.requiredString(payload, "endpoint")
    let rawArgs = payload["payload"]?["args"]?.objectValue ?? [:]
    let args = endpoint == "session/create" ? rawArgs : try await resolveNativeArguments(rawArgs)
    var body = payload["payload"]?.objectValue ?? [:]
    body["args"] = .object(args)
    payload["payload"] = .object(body)
    if let id = payload["sessionId"]?.stringValue {
      payload["sessionId"] = .string(try await nativeSessionID(for: id))
    }
    if Self.nativeActivityEndpoints.contains(endpoint) {
      return try await nativeActivityRPC(endpoint, payload: payload, epoch: epoch)
    }
    if endpoint == "session/create" {
      let result = try await nativeCreate(args, epoch: epoch)
      return .object(["ok": .bool(true), "value": result])
    }
    if endpoint == "session/updateQueue" || endpoint == "commands/execute" {
      return try await nativeExecution(endpoint, args: args, epoch: epoch)
    }
    if Self.nativeWorkspaceActions.contains(endpoint) {
      return try await nativeWorkspace(endpoint, args: args, envelope: payload, epoch: epoch)
    }
    if let action = Self.nativeWriteActions[endpoint] {
      let request = try Self.nativeRequest(args)
      let sessionID = try Self.requiredString(request, "sessionId")
      try await self.authorizeSession(sessionID, requiresProject: false)
      if endpoint == "session/prompt" { try Self.validateNativePrompt(request) }
      guard epoch == nativeClientEpoch, !isShuttingDown else { throw CancellationError() }
      let response = try await call(
        IPCEmbeddedDSHRequest(action: action, payloadJSON: Self.json(.object(request))))
      guard epoch == nativeClientEpoch, !isShuttingDown else { throw CancellationError() }
      try await authorizeSession(sessionID, requiresProject: false)
      let result = try JSONDecoder().decode(ACPJSONValue.self, from: Data(response.resultJSON.utf8))
      return .object(["ok": .bool(true), "value": result])
    }
    guard Self.nativeAuxiliaryEndpoints.contains(endpoint) else {
      throw ServiceStoreError.invalidArgument("embedded_dsh.client_endpoint")
    }
    _ = try await authorizeNativeEndpoint(endpoint, args: args)
    return try await invokeNative(action: "client.rpc", payload: payload, epoch: epoch)
  }

  private func resolveNativeArguments(_ values: [String: ACPJSONValue]) async throws -> [String:
    ACPJSONValue]
  {
    var result = values
    for (key, value) in values {
      if ["sessionId", "agentId", "parentSessionId", "childSessionId"].contains(key),
        let id = value.stringValue,
        let conversation = try await store.workbenchConversation(logicalSessionID: id)
      {
        result[key] = .string(conversation.nativeSessionID)
      } else if let nested = value.objectValue {
        result[key] = .object(try await resolveNativeArguments(nested))
      }
    }
    return result
  }

  private func nativeWorkspace(
    _ endpoint: String, args: [String: ACPJSONValue], envelope: [String: ACPJSONValue], epoch: Int
  ) async throws -> ACPJSONValue {
    let request = try Self.nativeRequest(args)
    let allowedKeys: Set<String> =
      endpoint == "workspace/archiveSession" ? ["sessionId", "stopActivity"] : ["sessionId"]
    guard Set(request.keys).isSubset(of: allowedKeys),
      request["stopActivity"] == nil || request["stopActivity"]?.boolValue != nil
    else { throw ServiceStoreError.invalidArgument("embedded_dsh.client_request") }
    let sessionID = try Self.requiredString(request, "sessionId")
    if let declaredSession = envelope["sessionId"], declaredSession != .string(sessionID) {
      throw ServiceStoreError.invalidArgument("embedded_dsh.session_project")
    }
    try await authorizeSession(sessionID, requiresProject: false)
    let projectID = try await storedProjectID(for: sessionID)
    if let declaredProject = envelope["projectID"],
      declaredProject != (projectID.map(ACPJSONValue.string) ?? .null)
    {
      throw ServiceStoreError.invalidArgument("embedded_dsh.session_project")
    }
    let workspacePath: String
    if let projectID {
      let project = try await registeredProject(projectID)
      workspacePath = project.root.canonicalPath
    } else {
      workspacePath =
        dataRoot.appendingPathComponent("WorkbenchChat", isDirectory: true).standardizedFileURL.path
    }
    let resolved = try await invokeNative(
      action: "client.workspaceSessionPath", payload: ["sessionId": .string(sessionID)],
      epoch: epoch)
    let path = try Self.requiredString(resolved.objectValue ?? [:], "path")
    guard Self.samePath(path, workspacePath) else {
      throw ServiceStoreError.invalidArgument("embedded_dsh.session_project")
    }
    let stopActivity = request["stopActivity"]?.boolValue == true
    if stopActivity {
      guard epoch == nativeClientEpoch, !isShuttingDown else { throw CancellationError() }
      _ = try await performDurableAction("session.stop", payload: ["sessionId": .string(sessionID)])
      try await self.authorizeSession(sessionID, requiresProject: false)
    }
    return try await invokeNative(
      action: "client.workspaceMutate",
      payload: [
        "endpoint": .string(endpoint), "sessionId": .string(sessionID),
        "projectPath": .string(workspacePath), "stopActivity": .bool(stopActivity),
      ], epoch: epoch)
  }

  private func nativeExecution(
    _ endpoint: String, args: [String: ACPJSONValue], epoch: Int
  ) async throws -> ACPJSONValue {
    var request: [String: ACPJSONValue]
    let action: String
    if endpoint == "session/updateQueue" {
      request = try Self.nativeRequest(args)
      guard let change = request["action"]?.objectValue,
        let kind = change["kind"]?.stringValue, ["edit", "remove", "steer"].contains(kind)
      else { throw ServiceStoreError.invalidArgument("embedded_dsh.queue_action") }
      if kind == "edit" { try Self.validateNativePrompt(change) }
      action = "session.updateQueue"
    } else {
      let id = try Self.requiredString(args, "agentId")
      let line = try Self.requiredString(args, "line")
      guard
        args["submittedAttachments"] == nil
          || args["submittedAttachments"]?.arrayValue == []
      else { throw ServiceStoreError.invalidArgument("embedded_dsh.attachments") }
      request = [
        "sessionId": .string(id), "line": .string(line), "submittedAttachments": .array([]),
      ]
      action = "commands.execute"
    }
    let sessionID = try Self.requiredString(request, "sessionId")
    try await authorizeSession(sessionID, requiresProject: false)
    guard epoch == nativeClientEpoch, !isShuttingDown else { throw CancellationError() }
    let response = try await invoke(action: action, payload: .object(request))
    guard epoch == nativeClientEpoch, !isShuttingDown else { throw CancellationError() }
    try await authorizeSession(sessionID, requiresProject: false)
    if endpoint == "commands/execute" {
      var envelope: [String: ACPJSONValue] = ["ok": .bool(true)]
      if let value = response["value"] { envelope["value"] = value }
      return .object(envelope)
    }
    return .object(["ok": .bool(true), "value": response])
  }

  private func nativeCreate(_ args: [String: ACPJSONValue], epoch: Int) async throws -> ACPJSONValue
  {
    var request = try Self.nativeRequest(args)
    if request["cwd"] == nil, request["workspaceId"] == nil {
      return try await createSession(request)
    }
    let requestedPath: String
    if let workspaceID = request["workspaceId"]?.stringValue, !workspaceID.isEmpty {
      let resolved = try await invokeNative(
        action: "client.workspacePath", payload: ["workspaceId": .string(workspaceID)], epoch: epoch
      )
      requestedPath = try Self.requiredString(resolved.objectValue ?? [:], "path")
      if let cwd = request["cwd"]?.stringValue, !Self.samePath(cwd, requestedPath) {
        throw ServiceStoreError.invalidArgument("embedded_dsh.session_project")
      }
    } else {
      requestedPath = try Self.requiredString(request, "cwd")
    }
    let registered = try await projects.projects()
    guard
      let project = registered.first(where: { Self.samePath($0.root.canonicalPath, requestedPath) })
    else { throw ServiceStoreError.invalidArgument("embedded_dsh.session_project") }
    try project.root.validateCurrentIdentity()
    request.removeValue(forKey: "workspaceId")
    request["projectID"] = .string(project.id.rawValue)
    guard epoch == nativeClientEpoch, !isShuttingDown else { throw CancellationError() }
    let result = try await createSession(request)
    guard epoch == nativeClientEpoch, !isShuttingDown else { throw CancellationError() }
    _ = try await registeredProject(project.id.rawValue)
    return result
  }

  private func openNativeStream(_ payload: [String: ACPJSONValue], epoch: Int) async throws
    -> ACPJSONValue
  {
    let id = try Self.nativeStreamID(payload)
    guard nativeClientStreams[id] == nil else {
      throw ServiceStoreError.invalidArgument("embedded_dsh.client_stream")
    }
    let endpoint = try Self.requiredString(payload, "endpoint")
    guard Self.nativeStreamEndpoints.contains(endpoint) else {
      throw ServiceStoreError.invalidArgument("embedded_dsh.client_endpoint")
    }
    let args = payload["payload"]?["args"]?.objectValue ?? [:]
    let sessionIDs = try await authorizeNativeEndpoint(endpoint, args: args)
    let result = try await invokeNative(
      action: "client.stream.open", payload: payload, epoch: epoch)
    nativeClientStreams[id] = NativeClientStream(sessionIDs: sessionIDs)
    return result
  }

  private func authorizeNativeEndpoint(_ endpoint: String, args: [String: ACPJSONValue])
    async throws
    -> [String]
  {
    switch endpoint {
    case "session/page", "session/follow":
      let request = try Self.nativeRequest(args)
      guard let address = request["address"]?.objectValue else {
        throw ServiceStoreError.invalidArgument("embedded_dsh.client_address")
      }
      switch address["kind"]?.stringValue {
      case "session":
        let id = try Self.requiredString(address, "sessionId")
        try await authorizeSession(id, requiresProject: false)
        return [id]
      case "subagent":
        let parent = try Self.requiredString(address, "parentSessionId")
        let child = try Self.requiredString(address, "childSessionId")
        let parentProject = try await project(for: parent)
        let children = try await invoke(
          action: "subagents.list", payload: .object(["sessionId": .string(parent)]))
        guard
          children["items"]?.arrayValue?.contains(where: {
            $0["sessionId"]?.stringValue == child && $0["parentSessionId"]?.stringValue == parent
          }) == true
        else { throw ServiceStoreError.invalidArgument("embedded_dsh.child") }
        try await bindSession(child, projectID: parentProject.id.rawValue)
        return [parent, child]
      default: throw ServiceStoreError.invalidArgument("embedded_dsh.client_address")
      }
    case "session/projections", "session/attachment", "skills/list", "job/list", "job/follow":
      let id = try Self.requiredString(Self.nativeRequest(args), "sessionId")
      try await authorizeSession(id, requiresProject: false)
      return [id]
    case "fileReferences/list":
      let id = try Self.requiredString(args, "agentId")
      try await authorizeSession(id, requiresProject: true)
      return [id]
    case "commands/list":
      let id = try Self.requiredString(args, "agentId")
      try await authorizeSession(id, requiresProject: false)
      return [id]
    default: return []
    }
  }

  func invokeNative(action: String, payload: [String: ACPJSONValue], epoch: Int)
    async throws
    -> ACPJSONValue
  {
    let scope = try await currentNativeScope()
    if nativeClientScope != scope {
      nativeClientScope = scope
      nativeClientStreams.removeAll()
    }
    var trusted = payload
    trusted["scope"] = scope.value
    if action == "client.stream.poll" { trusted["timeoutMs"] = .integer(200) }
    guard epoch == nativeClientEpoch, !isShuttingDown else { throw CancellationError() }
    let result = try await invoke(action: action, payload: .object(trusted))
    guard epoch == nativeClientEpoch, !isShuttingDown else { throw CancellationError() }
    let current = try await currentNativeScope()
    guard current == scope else {
      nativeClientScope = current
      nativeClientStreams.removeAll()
      guard epoch == nativeClientEpoch, !isShuttingDown else { throw CancellationError() }
      let reset = try await invoke(
        action: "client.stream.poll",
        payload: .object([
          "scope": current.value, "afterSequence": .integer(0), "timeoutMs": .integer(0),
        ]))
      guard epoch == nativeClientEpoch, !isShuttingDown, try await currentNativeScope() == current
      else { throw ServiceStoreError.storageBusy }
      if action == "client.stream.poll" { return reset }
      throw ServiceStoreError.storageBusy
    }
    return result
  }

  private static func nativeRequest(_ args: [String: ACPJSONValue]) throws -> [String: ACPJSONValue]
  {
    guard let request = args["request"]?.objectValue else {
      throw ServiceStoreError.invalidArgument("embedded_dsh.client_request")
    }
    return request
  }

  private static func nativeStreamID(_ payload: [String: ACPJSONValue]) throws -> String {
    let id = try requiredString(payload, "streamID")
    guard id.utf8.count <= 128 else {
      throw ServiceStoreError.invalidArgument("embedded_dsh.client_stream")
    }
    return id
  }

  private static func validateNativePrompt(_ request: [String: ACPJSONValue]) throws {
    guard let content = request["content"]?.arrayValue,
      content.allSatisfy({ $0["type"]?.stringValue == "text" && $0["text"]?.stringValue != nil })
    else { throw ServiceStoreError.invalidArgument("embedded_dsh.attachments") }
  }
}
