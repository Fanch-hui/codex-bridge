import BridgeACP
import BridgeAgentCore
import BridgeDomain
import BridgeServiceCore
import Foundation

extension ServiceEmbeddedDSHController {
  private static func submissionKey(rootID: String, childID: String, requestID: String) -> String {
    "embedded_dsh.submission."
      + digest([rootID, childID, requestID].joined(separator: "\0"))
  }

  static func subagentSubmissionFingerprint(_ payload: [String: ACPJSONValue]) throws -> String {
    let prompt = try requiredString(payload, "prompt")
    let values =
      [
        prompt, payload["installationID"]?.stringValue ?? "",
        payload["model"]?.stringValue ?? "", payload["effort"]?.stringValue ?? "",
      ] + (try subagentAttachmentPaths(payload))
    return digest(try json(.array(values.map(ACPJSONValue.string))))
  }

  func recordSubagentSubmission(
    fingerprint: String, requestID: String, rootID: String, childID: String
  ) async throws {
    let key = Self.submissionKey(rootID: rootID, childID: childID, requestID: requestID)
    if let previous = try await store.setting(key: key) {
      guard previous.value == fingerprint else {
        throw ServiceStoreError.invalidArgument("embedded_dsh.input_identity")
      }
      return
    }
    try await store.setSetting(
      ServiceSettingRecord(key: key, value: fingerprint, updatedAt: Date()))
  }

  func previousSubagentSubmission(
    _ payload: [String: ACPJSONValue], rootID: String, childID: String
  ) async throws -> ACPJSONValue? {
    let requestID = try Self.requiredString(payload, "requestID")
    guard
      let input = try await store.embeddedDSHInput(
        parentSessionID: rootID, childID: childID, requestID: requestID)
    else { return nil }
    guard let taskID = input.taskID, let task = try await store.task(id: taskID) else {
      throw ServiceStoreError.invalidArgument("dsh.subagentTaskRemoved")
    }
    let key = Self.submissionKey(rootID: rootID, childID: childID, requestID: requestID)
    if let saved = try await store.setting(key: key) {
      guard saved.value == (try Self.subagentSubmissionFingerprint(payload)) else {
        throw ServiceStoreError.invalidArgument("embedded_dsh.input_identity")
      }
    } else {
      let attachments = try await store.taskAttachments(taskID: taskID)
      guard task.prompt == (try Self.requiredString(payload, "prompt")),
        attachments.map(\.relativePath) == (try Self.subagentAttachmentPaths(payload))
      else { throw ServiceStoreError.invalidArgument("embedded_dsh.input_identity") }
    }
    return try await reconciledSubagentSubmission(
      rootID: rootID, childID: childID, taskID: taskID)
  }

  func reconciledSubagentSubmission(
    rootID: String, childID: String, taskID: TaskID
  ) async throws -> ACPJSONValue {
    let snapshot = try await application.serviceTask(
      taskID: taskID.rawValue, recentEventLimit: 1, deadline: .now.advanced(by: .seconds(30)))
    return .object([
      "childID": .string(childID), "taskID": .string(taskID.rawValue),
      "state": .string(snapshot.status),
      "waitingForApproval": .bool(snapshot.localApprovalRequired),
      "workspaceMode": .string(try await workspaceMode(rootID: rootID, childID: childID)),
    ])
  }

  func selectedSubagentTask(
    _ payload: [String: ACPJSONValue], rootID: String, binding: EmbeddedDSHSubagentBinding
  ) async throws -> TaskID {
    let selectedID = payload["taskID"]?.stringValue
    let requestID = payload["requestID"]?.stringValue
    let taskID: TaskID
    if let requestID {
      let input = try await store.embeddedDSHInput(
        parentSessionID: rootID, childID: binding.childID, requestID: requestID)
      if let id = input?.taskID {
        taskID = id
      } else {
        let key =
          "embedded_dsh.input."
          + Self.digest([rootID, binding.childID, requestID].joined(separator: "\0"))
        guard let saved = try await store.setting(key: key) else {
          throw ServiceStoreError.invalidArgument("embedded_dsh.child_request")
        }
        let previous = try JSONDecoder().decode(ACPJSONValue.self, from: Data(saved.value.utf8))
        guard let result = previous["result"]?["taskID"]?.stringValue else {
          throw ServiceStoreError.invalidArgument("embedded_dsh.child_request")
        }
        taskID = TaskID(rawValue: result)
      }
    } else if let selectedID {
      taskID = TaskID(rawValue: selectedID)
    } else if let current = binding.currentTaskID {
      taskID = current
    } else {
      throw ServiceStoreError.invalidArgument("embedded_dsh.child_task")
    }
    let owner = EmbeddedDSHSubagentIdentity(parentSessionID: rootID, childID: binding.childID)
    guard selectedID == nil || selectedID == taskID.rawValue,
      let task = try await store.task(id: taskID), task.projectID == binding.projectID,
      task.sourceClientID == owner.sourceClientID
    else { throw ServiceStoreError.invalidArgument("embedded_dsh.child_task_mismatch") }
    return taskID
  }

  func validateCurrentSubagentTask(
    _ payload: [String: ACPJSONValue], binding: EmbeddedDSHSubagentBinding,
    taskID: String, runID: String?
  ) throws {
    guard payload["taskID"]?.stringValue.map({ $0 == taskID }) != false,
      payload["runID"]?.stringValue.map({ $0 == runID }) != false,
      binding.currentTaskID?.rawValue == taskID
    else { throw ServiceStoreError.invalidArgument("embedded_dsh.child_run_mismatch") }
  }

  static func subagentAttachmentPaths(_ payload: [String: ACPJSONValue]) throws -> [String] {
    guard let value = payload["attachmentPaths"] else { return [] }
    guard let paths = value.arrayValue, paths.count <= AgentImageAttachmentLimits.maximumCount,
      paths.allSatisfy({ $0.stringValue != nil })
    else { throw ServiceStoreError.invalidArgument("embedded_dsh.attachments") }
    return paths.compactMap(\.stringValue)
  }
}
