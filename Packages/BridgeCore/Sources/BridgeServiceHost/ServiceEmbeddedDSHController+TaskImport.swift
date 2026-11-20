import BridgeACP
import BridgeDomain
import BridgeServiceCore
import Foundation

extension ServiceEmbeddedDSHController {
  /// Freezes the source once, before the operation is dispatched, so recovery sees the same data.
  func prepareTaskImport(_ request: [String: ACPJSONValue], operationID: String) async throws
    -> [String: ACPJSONValue]
  {
    let taskID = try Self.requiredString(request, "taskID")
    guard operationID == "workbench.importTask:" + taskID else {
      throw ServiceStoreError.invalidArgument("workbench.import_identity")
    }
    guard let task = try await store.task(id: TaskID(rawValue: taskID)) else {
      throw ServiceStoreError.invalidArgument("workbench.import_task")
    }
    guard !task.sourceClientID.hasPrefix("embedded.dsh.") else {
      throw ServiceStoreError.invalidArgument("workbench.import_source")
    }
    _ = try await registeredProject(task.projectID.rawValue)
    let instruction = Self.importText(task.prompt, maximum: 32 * 1024)
    let result =
      task.state.resultSummary.map { Self.importText($0, maximum: 12 * 1024) } ?? "暂无结果摘要"
    var files: [String] = []
    var fileBytes = 0
    for path in task.state.changedFiles.prefix(100) {
      let entry = Self.importText(path, maximum: 1024)
      let entryBytes = entry.utf8.count + 1
      guard fileBytes + entryBytes <= 12 * 1024 else { break }
      files.append(entry)
      fileBytes += entryBytes
    }
    let omitted = task.state.changedFiles.count - files.count
    var changes = files.joined(separator: "\n")
    if omitted > 0 { changes += "\n另有 \(omitted) 个文件未显示。" }
    if changes.isEmpty { changes = "暂无变更摘要" }
    return [
      "sessionId": .string(UUID().uuidString.lowercased()),
      "projectID": .string(task.projectID.rawValue),
      "taskID": .string(taskID), "readOnly": .bool(task.permissionMode == .readOnly),
      "text": .string("原任务指令：\n\(instruction)\n\n结果摘要：\n\(result)\n\n文件变更：\n\(changes)"),
    ]
  }

  func dispatchTaskImport(_ record: ServiceWorkbenchOperation) async throws -> ACPJSONValue {
    let frozen = try Self.decodeObject(record.draft.inputJSON)
    guard let dispatch = frozen["dispatch"]?.objectValue else {
      throw ServiceStoreError.invalidArgument("workbench.operation_input")
    }
    let sessionID = try Self.requiredString(dispatch, "sessionId")
    let projectID = try Self.requiredString(dispatch, "projectID")
    let taskID = try Self.requiredString(dispatch, "taskID")
    let created = try await createSession(dispatch, engineAction: "session.importTask")
    guard created["sessionId"] == .string(sessionID) else {
      throw ServiceStoreError.invalidArgument("embedded_dsh.session_response")
    }
    return .object([
      "accepted": .bool(true), "sessionID": .string(sessionID),
      "projectID": .string(projectID), "sourceTaskID": .string(taskID),
    ])
  }

  private static func importText(_ text: String, maximum: Int) -> String {
    guard text.utf8.count > maximum else { return text }
    return String(decoding: text.utf8.prefix(maximum), as: UTF8.self) + "…"
  }
}
