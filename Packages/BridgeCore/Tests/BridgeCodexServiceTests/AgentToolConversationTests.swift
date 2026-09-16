import BridgeAgentCore
import BridgeDomain
import BridgeServiceCore
import XCTest

@testable import BridgeCodexService

final class AgentToolConversationTests: XCTestCase {
  func testCompletedToolRetainsArgumentsAndPersistsFinalOutput() async throws {
    let fixture = try await makeExecutionFixture(self)
    let task = try await submitStartedExecutionTask(
      fixture: fixture,
      taskID: "tsk-agent-tool-completed"
    )
    let conversation = TaskConversationBuffer(
      tasks: fixture.tasks,
      flushDeltaCount: 1,
      flushInFlightCount: 1
    )
    let processor = ServiceExecutionAgentEventProcessor(
      tasks: fixture.tasks,
      projects: fixture.projects,
      conversation: conversation
    )
    let arguments = #"{"command":"echo done","cwd":"/tmp/project"}"#
    let output = "command finished with exit code 0"

    try await processor.process(
      .tool(
        try AgentToolUpdate(
          key: "tool-completed",
          name: "run_command",
          status: .inProgress,
          arguments: arguments
        )
      ),
      taskID: task.id
    )
    try await processor.process(
      .tool(
        try AgentToolUpdate(
          key: "tool-completed",
          name: "run_command",
          status: .completed,
          output: output
        )
      ),
      taskID: task.id
    )

    let entries = await conversation.entries(taskID: task.id)
    let entry = try XCTUnwrap(entries.first)
    XCTAssertEqual(entry.toolStatus, ExecutionToolCallStatus.completed.rawValue)
    XCTAssertEqual(entry.toolArguments, arguments)
    XCTAssertTrue(entry.isFinal)
    XCTAssertTrue(entry.content.contains(output))

    let closed = await conversation.close(taskID: task.id)
    XCTAssertTrue(closed)
    let persisted = try await fixture.store.taskMessages(taskID: task.id)
    XCTAssertEqual(persisted.count, 1)
    XCTAssertEqual(persisted[0].toolStatus, ExecutionToolCallStatus.completed.rawValue)
    XCTAssertEqual(persisted[0].toolArguments, arguments)
    XCTAssertTrue(persisted[0].content.contains(output))
  }

  func testCancelledToolRemainsCancelled() async throws {
    let fixture = try await makeExecutionFixture(self)
    let task = try await submitStartedExecutionTask(
      fixture: fixture,
      taskID: "tsk-agent-tool-cancelled"
    )
    let conversation = TaskConversationBuffer(
      tasks: fixture.tasks,
      flushDeltaCount: 1,
      flushInFlightCount: 1
    )
    let processor = ServiceExecutionAgentEventProcessor(
      tasks: fixture.tasks,
      projects: fixture.projects,
      conversation: conversation
    )

    try await processor.process(
      .tool(
        try AgentToolUpdate(
          key: "tool-cancelled",
          name: "run_command",
          status: .inProgress,
          arguments: #"{"command":"sleep 1"}"#
        )
      ),
      taskID: task.id
    )
    try await processor.process(
      .tool(
        try AgentToolUpdate(
          key: "tool-cancelled",
          name: "run_command",
          status: .cancelled
        )
      ),
      taskID: task.id
    )

    let entries = await conversation.entries(taskID: task.id)
    let entry = try XCTUnwrap(entries.first)
    XCTAssertEqual(entry.toolStatus, ExecutionToolCallStatus.cancelled.rawValue)
    XCTAssertNotEqual(entry.toolStatus, ExecutionToolCallStatus.failed.rawValue)
    XCTAssertTrue(entry.isFinal)

    let closed = await conversation.close(taskID: task.id)
    XCTAssertTrue(closed)
    let persisted = try await fixture.store.taskMessages(taskID: task.id)
    XCTAssertEqual(persisted[0].toolStatus, ExecutionToolCallStatus.cancelled.rawValue)
  }
}
