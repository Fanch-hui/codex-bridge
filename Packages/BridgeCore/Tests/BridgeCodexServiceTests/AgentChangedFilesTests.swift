import BridgeAgentCore
import BridgeCodexService
import BridgeDomain
import BridgeServiceCore
import Foundation
import XCTest

final class AgentChangedFilesTests: XCTestCase {
  func testProviderRunWithoutFileLocationsStillPersistsWorkspaceChanges() async throws {
    let fixture = try await makeExecutionFixture(self)
    let taskID = TaskID(rawValue: "tsk-agent-workspace-change")
    let submitted = try await fixture.tasks.submit(
      ServiceTaskRequest(
        projectID: fixture.project.id,
        source: .chatGPT,
        clientRequestID: "request-agent-workspace-change",
        prompt: "Create a file.",
        providerID: "opencode",
        installationID: "ainst-agent-workspace-change",
        selectionMode: .explicit,
        executionModel: serviceDefaultProviderExecutionModel,
        executionEffort: serviceDefaultProviderExecutionEffort,
        permissionMode: .workspaceWrite
      ),
      taskID: taskID
    )
    _ = try await fixture.tasks.begin(taskID: submitted.task.id)
    let runner = FileWritingAgentRunner(root: fixture.root)
    let coordinator = ServiceExecutionCoordinator(
      tasks: fixture.tasks,
      projects: fixture.projects,
      execution: makeExecutionManager(script: "exit 0"),
      agentRunner: runner
    )
    addTeardownBlock { await coordinator.shutdown() }

    _ = try await coordinator.start(taskID: taskID)
    try await Task.sleep(for: .milliseconds(20))
    await runner.complete(taskID: taskID)

    let completed: ServiceTaskRecord
    do {
      completed = try await waitForTask(fixture, taskID: taskID) {
        $0.state.status == .completed
      }
    } catch {
      let current = try await fixture.tasks.task(id: taskID)
      let events = try await fixture.tasks.events(taskID: taskID, limit: 20)
      XCTFail(
        "Task did not complete: \(String(describing: current?.state.status)) "
          + "failure=\(current?.state.failureCode ?? "nil") "
          + "summary=\(current?.state.resultSummary ?? "nil") "
          + "events=\(events.map(\.kind))"
      )
      throw error
    }
    XCTAssertEqual(completed.state.changedFiles, ["agent-created.txt"])
  }
}

private actor FileWritingAgentRunner: AgentTaskRunning {
  private let root: URL
  private var continuation: AsyncThrowingStream<AgentEventEnvelope, any Error>.Continuation?
  private var sessionID = ""
  private var runID = ""

  init(root: URL) {
    self.root = root
  }

  func start(_ brief: AgentTaskBrief) async throws -> AgentTaskRunHandle {
    let pair = AsyncThrowingStream.makeStream(
      of: AgentEventEnvelope.self,
      throwing: (any Error).self
    )
    continuation = pair.continuation
    sessionID = "session-\(brief.taskID.rawValue)"
    runID = "run-\(brief.taskID.rawValue)"
    return AgentTaskRunHandle(
      sessionID: sessionID,
      runID: runID,
      events: pair.stream,
      interrupt: {},
      shutdown: { [weak self] in await self?.finish() }
    )
  }

  func complete(taskID: TaskID) {
    try? Data("created by a command".utf8).write(to: root.appending(path: "agent-created.txt"))
    if let event = try? AgentEventEnvelope(
      taskID: taskID,
      providerID: .openCode,
      providerSessionID: sessionID,
      providerRunID: runID,
      providerSequence: 0,
      event: .completed(summary: "Created the file.", stopReason: "end_turn")
    ) {
      _ = continuation?.yield(event)
    }
    continuation?.finish()
    continuation = nil
  }

  func finish() {
    continuation?.finish()
    continuation = nil
  }
}
