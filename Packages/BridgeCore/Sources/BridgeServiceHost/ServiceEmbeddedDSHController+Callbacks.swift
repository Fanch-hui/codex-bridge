import BridgeACP
import BridgeAgentCore
import BridgeDomain
import BridgeMCP
import BridgeSecurity
import BridgeServiceCore
import Crypto
import Foundation

extension ServiceEmbeddedDSHController {
  func secret(_ input: ACPJSONValue) throws -> ACPJSONValue {
    guard let payload = input.objectValue else {
      throw ServiceStoreError.invalidArgument("embedded_dsh.secret")
    }
    let key = try Self.requiredString(payload, "key")
    let scope = SHA256.hash(data: Data(dataRoot.standardizedFileURL.path.utf8))
      .map { String(format: "%02x", $0) }.joined().prefix(16)
    let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    let reference = try SecretReference(validating: "embedded-dsh.\(scope).\(digest)")
    switch try Self.requiredString(payload, "operation") {
    case "get":
      do {
        let data = try secretStore.load(reference)
        let value = try JSONDecoder().decode(ACPJSONValue.self, from: data)
        return .object(["value": value])
      } catch SecretStoreError.notFound {
        return .object(["value": .null])
      }
    case "set":
      guard let value = payload["value"] else {
        throw ServiceStoreError.invalidArgument("embedded_dsh.secret_value")
      }
      try secretStore.store(try value.encodedData(), for: reference)
      return .object([:])
    case "delete":
      try secretStore.remove(reference)
      return .object([:])
    default: throw ServiceStoreError.invalidArgument("embedded_dsh.secret_operation")
    }
  }

  func agents(_ input: ACPJSONValue) async throws -> ACPJSONValue {
    let projectID: String?
    if let sessionID = input["rootSessionID"]?.stringValue ?? input["sessionID"]?.stringValue {
      projectID = try await project(for: sessionID).id.rawValue
    } else {
      projectID = nil
    }
    let deadline = ContinuousClock.now.advanced(by: .seconds(40))
    let catalog = try await application.serviceAgents(projectID: projectID, deadline: deadline)
    var result: [ACPJSONValue] = []
    result.reserveCapacity(catalog.agents.count + 1)
    for agent in catalog.agents {
      let defaults = try? await application.serviceAgentModelDefault(
        providerID: AgentProviderID(rawValue: agent.providerID), deadline: deadline)
      result.append(
        .object([
          "installationID": .string(agent.installationID), "providerID": .string(agent.providerID),
          "displayName": .string(agent.displayName),
          "available": .bool(agent.enabled && agent.taskSubmissionEnabled),
          "capabilities": .array(agent.effectiveCapabilities.map(ACPJSONValue.string)),
          "defaultModel": defaults?.model.map(ACPJSONValue.string) ?? .null,
          "defaultReasoningEffort": defaults?.effort.map(ACPJSONValue.string) ?? .null,
        ]))
    }
    let status = try await application.serviceStatus(deadline: deadline)
    result.insert(
      .object([
        "installationID": .string("codex"), "providerID": .string("codex"),
        "displayName": .string("Codex"),
        "available": .bool(status.codexResolvedExecutablePath != nil),
        "capabilities": .array([.string("readOnlyExecution"), .string("steer")]),
      ]), at: 0)
    return .object(["agents": .array(result)])
  }

  func agentModels(_ input: ACPJSONValue) async throws -> ACPJSONValue {
    guard let payload = input.objectValue else {
      throw ServiceStoreError.invalidArgument("embedded_dsh.agent_models")
    }
    let installationID = try Self.requiredString(payload, "installationID")
    let deadline = ContinuousClock.now.advanced(by: .seconds(40))
    if installationID == "codex" {
      let catalog = try await application.serviceModels(deadline: deadline)
      return .object([
        "models": .array(
          catalog.models.map { model in
            .object([
              "id": .string(model.modelID), "name": .string(model.displayName),
              "reasoningEfforts": .array(model.reasoningEfforts.map(ACPJSONValue.string)),
            ])
          })
      ])
    }
    let sessionID = payload["rootSessionID"]?.stringValue ?? payload["sessionID"]?.stringValue
    let projectID: String?
    if let sessionID {
      projectID = try await project(for: sessionID).id.rawValue
    } else {
      projectID = nil
    }
    let catalog = try await application.serviceAgentModels(
      installationID: installationID, projectID: projectID, modelID: nil,
      forceRefresh: payload["forceRefresh"]?.boolValue ?? false, deadline: deadline)
    let matchedInstallation = try? await application.serviceManagedAgentInstallations(
      deadline: deadline
    ).first(where: { $0.id.rawValue == installationID })
    let defaults =
      if let providerID = matchedInstallation?.providerID {
        try? await application.serviceAgentModelDefault(providerID: providerID, deadline: deadline)
      } else {
        nil as (model: String?, permissionMode: String, effort: String?)?
      }
    return .object([
      "defaultModel": defaults?.model.map(ACPJSONValue.string) ?? .null,
      "defaultReasoningEffort": defaults?.effort.map(ACPJSONValue.string) ?? .null,
      "models": .array(
        catalog.models.map { model in
          .object([
            "id": .string(model.modelID), "name": .string(model.displayName),
            "reasoningEfforts": .array(model.reasoningEfforts.map(ACPJSONValue.string)),
            "defaultReasoningEffort": model.defaultReasoningEffort.map(ACPJSONValue.string)
              ?? .null,
            "isDefault": model.isDefault.map(ACPJSONValue.bool) ?? .null,
          ])
        }),
    ])
  }

  func execution(_ input: ACPJSONValue) async throws -> ACPJSONValue {
    guard let payload = input.objectValue else {
      throw ServiceStoreError.invalidArgument("embedded_dsh.execution")
    }
    await inputGate.acquire()
    defer { inputGate.release() }
    let sessionID = try Self.requiredString(payload, "sessionID")
    let logicalID = nativeLogicalIDs[sessionID] ?? sessionID
    let generation = try await store.workbenchGeneration(sessionID: logicalID)
    if payload["operation"]?.stringValue == "end",
      let sourceGeneration = payload["executionGeneration"]?.intValue,
      Int64(sourceGeneration) != generation.generation
    {
      return .object([:])
    }
    if generation.closed {
      if payload["operation"]?.stringValue == "begin" { throw CancellationError() }
      if payload["operation"]?.stringValue == "end" { return .object([:]) }
    }
    if payload["operation"]?.stringValue == "begin",
      isApplyingConfiguration || isChangingWorkbenchEnabled
    {
      throw ServiceStoreError.storageBusy
    }
    if try await storedProjectID(for: sessionID) == nil {
      try await authorizeSession(sessionID, requiresProject: false)
      let logicalID = nativeLogicalIDs[sessionID] ?? sessionID
      if payload["operation"]?.stringValue == "begin" {
        let group = try await application.beginUnscopedWorkbenchExecution(sessionID: logicalID)
        return .object([
          "groupID": .string(group), "executionGeneration": .integer(generation.generation),
        ])
      }
      if payload["operation"]?.stringValue == "end" {
        await application.finishUnscopedWorkbenchExecution(sessionID: logicalID)
        return .object([:])
      }
      throw ServiceStoreError.invalidArgument("workbench.execution_operation")
    }
    guard let projectID = try await storedProjectID(for: sessionID) else {
      throw ServiceStoreError.invalidArgument("embedded_dsh.session")
    }
    switch try Self.requiredString(payload, "operation") {
    case "begin":
      let project = try await project(for: sessionID)
      try await validateWorkspaceWriteRecovery(projectID: project.id)
      let mode: ServicePermissionMode =
        payload["permissionMode"]?.stringValue == "read-only" ? .readOnly : .full
      let groupID = try await application.beginEmbeddedDSHExecution(
        sessionID: sessionID, projectID: project.id, permissionMode: mode)
      return .object([
        "groupID": .string(groupID), "executionGeneration": .integer(generation.generation),
      ])
    case "end":
      try await validateWorkspaceWriteRecovery(projectID: ProjectID(rawValue: projectID))
      try await application.finishEmbeddedDSHExecution(
        sessionID: sessionID, projectID: ProjectID(rawValue: projectID))
      return .object([:])
    default: throw ServiceStoreError.invalidArgument("embedded_dsh.execution_operation")
    }
  }

  func stopSession(_ payload: [String: ACPJSONValue], releasesExecution: Bool = true) async throws
    -> ACPJSONValue
  {
    let sessionID = try Self.requiredString(payload, "sessionId")
    let logicalID = nativeLogicalIDs[sessionID] ?? sessionID
    try await stopProjectBinding(logicalID, releasesExecution: releasesExecution)
    if try await storedProjectID(for: sessionID) == nil {
      try await authorizeSession(sessionID, requiresProject: false)
      let result = try await invoke(action: "session.stop", payload: .object(payload))
      if releasesExecution {
        await application.finishUnscopedWorkbenchExecution(sessionID: logicalID)
      }
      try await clearWorkspaceRequest(logicalID)
      return result
    }
    guard let projectID = try await storedProjectID(for: sessionID) else {
      throw ServiceStoreError.invalidArgument("embedded_dsh.session")
    }
    try await application.closeEmbeddedDSHExecutionAdmission(
      sessionID: sessionID, projectID: ProjectID(rawValue: projectID))
    let result = try await invoke(action: "session.stop", payload: .object(payload))
    try await application.stopEmbeddedDSHExecution(
      sessionID: sessionID,
      projectID: ProjectID(rawValue: projectID), releasesRoot: releasesExecution)
    if releasesExecution {
      await application.finishUnscopedWorkbenchExecution(sessionID: logicalID)
    }
    try await clearWorkspaceRequest(logicalID)
    return result
  }
}
