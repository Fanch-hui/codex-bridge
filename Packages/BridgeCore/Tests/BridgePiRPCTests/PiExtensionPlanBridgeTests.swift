import BridgeAgentCore
import BridgeDomain
import Foundation
import Testing

@testable import BridgePiRPC

struct PiExtensionPlanBridgeTests {
  @Test func acceptsOnlyCurrentTaskPlanSnapshot() throws {
    let taskID = TaskID(rawValue: "task-123")
    let payload = PiJSONValue.object([
      "revision": .integer(1), "nonce": .string("nonce-1"),
      "taskID": .string(taskID.rawValue),
      "items": .array([
        .object([
          "id": .string("inspect"), "content": .string("Inspect the project"),
          "priority": .string("high"), "status": .string("in_progress"),
        ]),
        .object([
          "id": .string("fix"), "content": .string("Fix the issue"),
          "priority": .string("normal"), "status": .string("pending"),
        ]),
      ]),
    ])
    let status = PiJSONValue.object([
      "type": .string("extension_ui_request"), "method": .string("setStatus"),
      "statusKey": .string(PiExtensionPlanBridge.statusKey),
      "statusText": .string(try payload.text()),
    ])

    let parsed = try PiExtensionPlanBridge.plan(status, nonce: "nonce-1", taskID: taskID)
    let plan = try #require(parsed)
    let expected = [
      try AgentPlanEntry(content: "Inspect the project", priority: "high", status: "in_progress"),
      try AgentPlanEntry(content: "Fix the issue", priority: "normal", status: "pending"),
    ]
    #expect(plan == expected)
  }

  @Test func ignoresUnrelatedExtensionStatus() throws {
    let status = PiJSONValue.object([
      "type": .string("extension_ui_request"), "method": .string("setStatus"),
      "statusKey": .string("some-other-extension"), "statusText": .string("{}"),
    ])
    #expect(
      try PiExtensionPlanBridge.plan(status, nonce: "nonce", taskID: TaskID(rawValue: "task"))
        == nil)
  }

  @Test func rejectsMismatchedOrDuplicatePlanIdentity() throws {
    let taskID = TaskID(rawValue: "task-123")
    let payload = PiJSONValue.object([
      "revision": .integer(1), "nonce": .string("nonce-1"),
      "taskID": .string(taskID.rawValue),
      "items": .array([
        .object([
          "id": .string("same"), "content": .string("First"),
          "priority": .string("normal"), "status": .string("pending"),
        ]),
        .object([
          "id": .string("same"), "content": .string("Second"),
          "priority": .string("normal"), "status": .string("completed"),
        ]),
      ]),
    ])
    let status = PiJSONValue.object([
      "type": .string("extension_ui_request"), "method": .string("setStatus"),
      "statusKey": .string(PiExtensionPlanBridge.statusKey),
      "statusText": .string(try payload.text()),
    ])

    #expect(throws: PiRPCError.invalidRecord) {
      try PiExtensionPlanBridge.plan(status, nonce: "different", taskID: taskID)
    }
    #expect(throws: PiRPCError.invalidRecord) {
      try PiExtensionPlanBridge.plan(status, nonce: "nonce-1", taskID: taskID)
    }
  }
}
