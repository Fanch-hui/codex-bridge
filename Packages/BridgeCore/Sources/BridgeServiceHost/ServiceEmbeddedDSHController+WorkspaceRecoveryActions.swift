import BridgeACP
import BridgeDomain
import BridgeEmbeddedDSH
import BridgeServiceCore
import Crypto
import Foundation

private struct WorkspaceRecoveryReceipt: Codable, Sendable {
  let id: String
  let value: ACPJSONValue
}

extension ServiceEmbeddedDSHController {
  func workspaceRecoveryAction(_ action: String, payload: [String: ACPJSONValue])
    async throws -> ACPJSONValue
  {
    let projectID = ProjectID(rawValue: try Self.requiredString(payload, "projectID"))
    _ = try await registeredProject(projectID.rawValue)
    if action == "workspace.recovery.list" {
      let native = try await invoke(action: "workspace.recovery.check", payload: .object([:]))
      try await reconcileNativeWorkspaceRecovery()
      var items = try await nativeRecoveryItems(native, projectID: projectID)
      items += try await mergeWorkspaceRecoveryItems(projectID: projectID)
      return .object(["items": .array(items)])
    }
    let recoveryID = try Self.requiredString(payload, "recoveryID")
    let permitted = [
      "workspace.recovery.check", "workspace.recovery.terminate", "workspace.recovery.resume",
      "workspace.recovery.rollback", "workspace.recovery.confirmLegacy",
    ]
    guard permitted.contains(action) else {
      throw ServiceStoreError.invalidArgument("workbench.workspace_recovery_action")
    }
    if action == "workspace.recovery.confirmLegacy", payload["confirmed"]?.boolValue != true {
      throw ServiceStoreError.invalidArgument("workbench.workspace_recovery_confirmation")
    }
    await workspaceRecoveryGate.acquire()
    defer { workspaceRecoveryGate.release() }
    let receiptKey = Self.workspaceRecoveryReceiptKey(
      action: action, recoveryID: recoveryID, projectID: projectID)
    let receiptsKey = Self.workspaceRecoveryReceiptKey(
      action: "receipts", recoveryID: "", projectID: projectID)
    if action != "workspace.recovery.check",
      let stored = try await store.setting(key: receiptsKey),
      let receipt = try JSONDecoder().decode(
        [WorkspaceRecoveryReceipt].self, from: Data(stored.value.utf8)
      )
      .first(where: { $0.id == receiptKey })
    {
      return receipt.value
    }
    let result = try await dispatchWorkspaceRecovery(
      action, projectID: projectID, recoveryID: recoveryID)
    if action == "workspace.recovery.check" { return result }
    return try await persistWorkspaceRecoveryReceipt(result, id: receiptKey, key: receiptsKey)
  }

  private func dispatchWorkspaceRecovery(
    _ action: String, projectID: ProjectID, recoveryID: String
  ) async throws -> ACPJSONValue {
    let mergeItems = try await mergeWorkspaceRecoveryItems(projectID: projectID)
    if mergeItems.contains(where: { $0["recoveryID"]?.stringValue == recoveryID }) {
      switch action {
      case "workspace.recovery.resume", "workspace.recovery.rollback":
        return try await recoverWorkspaceMerge(
          recoveryID: recoveryID, projectID: projectID,
          rollback: action == "workspace.recovery.rollback")
      case "workspace.recovery.check": return .object(["items": .array(mergeItems)])
      default: throw ServiceStoreError.invalidArgument("workbench.workspace_recovery_action")
      }
    }
    let state = try await invoke(action: "workspace.recovery.list", payload: .object([:]))
    let items = try await nativeRecoveryItems(state, projectID: projectID)
    guard let item = items.first(where: { $0["recoveryID"]?.stringValue == recoveryID }),
      let sessionID = item["nativeSessionId"]?.stringValue
    else { throw ServiceStoreError.invalidArgument("workbench.workspace_recovery_missing") }
    guard action != "workspace.recovery.rollback" else {
      throw ServiceStoreError.invalidArgument("workbench.workspace_recovery_action")
    }
    var input: [String: ACPJSONValue] = [
      "sessionId": .string(sessionID), "recoveryID": .string(recoveryID),
    ]
    if action == "workspace.recovery.confirmLegacy" {
      input["confirmed"] = .bool(true)
    }
    if action == "workspace.recovery.resume" {
      _ = try await invoke(action: "workspace.recovery.check", payload: .object(input))
      try await reconcileNativeWorkspaceRecovery()
    }
    var result = try await invoke(action: action, payload: .object(input)).objectValue ?? [:]
    if action != "workspace.recovery.resume" {
      try await reconcileNativeWorkspaceRecovery()
    }
    result["sessionId"] = .string(nativeLogicalIDs[sessionID] ?? sessionID)
    return .object(result)
  }

  private static func workspaceRecoveryReceiptKey(
    action: String, recoveryID: String, projectID: ProjectID
  ) -> String {
    let input = projectID.rawValue + "\0" + recoveryID + "\0" + action
    let digest = SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    return "embedded_dsh.workspace.recovery_receipt." + digest
  }

  private func persistWorkspaceRecoveryReceipt(_ result: ACPJSONValue, id: String, key: String)
    async throws -> ACPJSONValue
  {
    var receipt: [String: ACPJSONValue] = ["accepted": .bool(true)]
    for field in ["sessionId", "resumed", "status"] {
      if let value = result[field] { receipt[field] = value }
    }
    let completed = WorkspaceRecoveryReceipt(id: id, value: .object(receipt))
    try await store.updateSettingsAtomically(keys: [key], updatedAt: Date()) { stored in
      var receipts =
        try stored[key].map {
          try JSONDecoder().decode([WorkspaceRecoveryReceipt].self, from: Data($0.utf8))
        } ?? []
      receipts.removeAll { $0.id == id }
      receipts.append(completed)
      receipts = Array(receipts.suffix(64))
      let encoder = JSONEncoder()
      var data = try encoder.encode(receipts)
      while data.count > 48 * 1_024, receipts.count > 1 {
        receipts.removeFirst()
        data = try encoder.encode(receipts)
      }
      return [key: String(decoding: data, as: UTF8.self)]
    }
    return result
  }

  private func nativeRecoveryItems(_ state: ACPJSONValue, projectID: ProjectID)
    async throws -> [ACPJSONValue]
  {
    var items: [ACPJSONValue] = []
    for item in state["items"]?.arrayValue ?? [] {
      guard var fields = item.objectValue, let sessionID = fields["sessionId"]?.stringValue,
        try await storedProjectID(for: sessionID) == projectID.rawValue
      else { continue }
      fields["nativeSessionId"] = .string(sessionID)
      fields["sessionId"] = .string(nativeLogicalIDs[sessionID] ?? sessionID)
      fields["projectID"] = .string(projectID.rawValue)
      items.append(.object(fields))
    }
    return items
  }

  func reconcileNativeWorkspaceRecovery() async throws {
    await inputGate.acquire()
    defer { inputGate.release() }
    let state = try await invoke(action: "workspace.recovery.list", payload: .object([:]))
    for item in state["items"]?.arrayValue ?? [] {
      guard item["status"]?.stringValue == "exited",
        item["executionActive"]?.boolValue == false,
        let rootID = item["sessionId"]?.stringValue,
        let execution = try await application.embeddedDSHExecution(sessionID: rootID),
        execution.rootActive
      else { continue }
      try await validateWorkspaceWriteRecovery(projectID: execution.projectID)
      try await application.finishEmbeddedDSHExecution(
        sessionID: rootID, projectID: execution.projectID)
    }
  }

  func validateNativeWorkspaceWrite(_ input: ACPJSONValue) async throws -> ACPJSONValue {
    guard let sessionID = input["sessionID"]?.stringValue else {
      throw ServiceStoreError.invalidArgument("workbench.workspace_write")
    }
    let project = try await project(for: sessionID)
    if try await application.pendingWorkspaceMergeRecovery(projectID: project.id) != nil {
      throw ServiceStoreError.invalidArgument("workbench.workspace_merge_recovery_required")
    }
    return .object(["allowed": .bool(true)])
  }
}
