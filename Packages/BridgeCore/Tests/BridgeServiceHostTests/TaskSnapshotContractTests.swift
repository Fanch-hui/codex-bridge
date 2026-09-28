import BridgeIPC
import Foundation
import XCTest

@testable import BridgeMCP

final class TaskSnapshotContractTests: XCTestCase {
  private let legacyTask = #"""
    {
      "task_id": "task-contract", "project_id": "project-contract",
      "status": "interrupted", "supervisor_status": "disabled",
      "local_approval_required": false, "updated_at": "2026-09-27T00:00:00Z"
    }
    """#

  func testLegacyTaskRemainsReadableThroughMCPAndIPC() throws {
    let mcp = try JSONDecoder().decode(
      ServiceGetTaskOutput.self,
      from: Data("{\"schema_version\":1,\"task\":\(legacyTask)}".utf8)
    )
    let listPayload = Data("{\"tasks\":[\(legacyTask)]}".utf8).base64EncodedString()
    let response = Data(
      """
      {"schema_version":4,"request_id":"contract-check","payload":"\(listPayload)"}
      """.utf8
    )
    let ipc = try BridgeServiceIPCCodec.decodeResponse(
      IPCTaskListResponse.self, data: response, requestID: "contract-check"
    )

    XCTAssertEqual(ipc.tasks, [mcp.task])
    XCTAssertEqual(mcp.task.taskID, "task-contract")
    XCTAssertEqual(mcp.task.status, "interrupted")
    XCTAssertEqual(mcp.task.attachmentPaths, [])
    XCTAssertEqual(mcp.task.changedFiles, [])
    XCTAssertFalse(mcp.task.networkAccess)
    XCTAssertNil(mcp.task.usage)
  }

  func testTaskFieldsKeepPublishedNamesInBothTransports() throws {
    let task = try JSONDecoder().decode(MCPServiceTaskSnapshot.self, from: Data(legacyTask.utf8))
    let mcp = try object(JSONEncoder().encode(ServiceGetTaskOutput(task: task)))
    let response = try BridgeServiceIPCCodec.success(
      requestID: "contract-check", payload: IPCTaskListResponse(tasks: [task])
    )
    let payload = try XCTUnwrap(BridgeServiceIPCCodec.response(response).payload)
    let ipc = try object(payload)
    let mcpTask = try XCTUnwrap(mcp["task"] as? NSDictionary)
    let ipcTask = try XCTUnwrap((ipc["tasks"] as? [NSDictionary])?.first)

    XCTAssertEqual(mcp["schema_version"] as? Int, 1)
    XCTAssertEqual(mcpTask, ipcTask)
    for key in [
      "task_id", "project_id", "status", "supervisor_status", "local_approval_required",
      "updated_at", "attachment_paths", "changed_files", "network_access",
    ] {
      XCTAssertNotNil(mcpTask[key], "Published task field missing: \(key)")
    }
  }

  private func object(_ data: Data) throws -> [String: Any] {
    try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }
}
