import BridgeAgentCore
@testable import BridgeAntigravityCLI
import BridgeDomain
import BridgeProcess
import Foundation
import XCTest

private final class MockAntigravityCLITransport: AntigravityCLITransport, @unchecked Sendable {
  let incomingStream: AsyncThrowingStream<Data, any Error>
  let incomingContinuation: AsyncThrowingStream<Data, any Error>.Continuation
  var stderrSnapshot: BoundedProcessOutput

  var incoming: AsyncThrowingStream<Data, any Error> { incomingStream }

  init(stderr: String = "") {
    let (stream, continuation) = AsyncThrowingStream.makeStream(of: Data.self)
    self.incomingStream = stream
    self.incomingContinuation = continuation
    self.stderrSnapshot = BoundedProcessOutput(head: stderr, tail: "")
  }

  func send(_ frame: Data) async throws {}
  func interrupt() async {}
  func standardErrorSnapshot() async -> BoundedProcessOutput { stderrSnapshot }
  func close() async { incomingContinuation.finish() }

  func pushFrame(_ string: String) {
    if let data = string.data(using: .utf8) {
      incomingContinuation.yield(data)
    }
  }

  func finish() {
    incomingContinuation.finish()
  }
}

final class AntigravityCLIExecutionTests: XCTestCase {
  private let testProjectRoot =
    AntigravityCLILaunchRuntime.canonicalFoundationPath(NSTemporaryDirectory())
    ?? NSTemporaryDirectory()

  private func makeExecution(
    transport: MockAntigravityCLITransport,
    prompt: String = "Test prompt"
  ) -> AntigravityCLIExecution {
    AntigravityCLIExecution(
      taskID: TaskID(rawValue: "task-test-1"),
      installationID: AgentInstallationID(rawValue: "inst-test-1"),
      projectRoot: testProjectRoot,
      requestedSessionID: nil,
      prompt: prompt,
      transport: transport,
      cleanup: {}
    )
  }

  private func jsonEscape(_ string: String) -> String {
    string
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
  }

  private func pushInit(on transport: MockAntigravityCLITransport, sessionID: String = "session-1") {
    let escapedCwd = jsonEscape(testProjectRoot)
    transport.pushFrame("""
      {"event":"init","conversation_id":"\(sessionID)","init":{"cwd":"\(escapedCwd)","tools":["bridge_run_command"],"permission_mode":"always-proceed"}}
      """)
  }

  private func pushToolStep(
    on transport: MockAntigravityCLITransport,
    sessionID: String = "session-1",
    stepIndex: Int,
    state: String = "DONE",
    isPermissionDenied: Bool = false,
    errorMessage: String? = nil,
    output: String? = nil
  ) {
    let errorPart: String
    if isPermissionDenied {
      let msg = jsonEscape(errorMessage ?? "Permission denied: native AGY policy requires review; the Bridge MCP command was not run.")
      errorPart = ",\"error\":{\"message\":\"\(msg)\"}"
    } else if let errorMessage {
      let msg = jsonEscape(errorMessage)
      errorPart = ",\"error\":{\"message\":\"\(msg)\"}"
    } else {
      errorPart = ""
    }
    let outputPart = output.map { ",\"output\":\"\(jsonEscape($0))\"" } ?? ""
    transport.pushFrame("""
      {"event":"step_update","step_update":{"conversation_id":"\(sessionID)","step_index":\(stepIndex),"state":"\(state)","step_type":"tool","tool_name":"bridge_run_command","tool_info":{"name":"bridge_run_command"\(errorPart)\(outputPart)}}}
      """)
  }

  private func pushResult(
    on transport: MockAntigravityCLITransport,
    sessionID: String = "session-1",
    status: String = "SUCCESS",
    error: String? = nil,
    response: String = "Finished"
  ) {
    let errorPart = error.map { ",\"error\":\"\(jsonEscape($0))\"" } ?? ""
    transport.pushFrame("""
      {"event":"result","result":{"conversation_id":"\(sessionID)","status":"\(status)","response":"\(jsonEscape(response))"\(errorPart)}}
      """)
  }

  // MARK: - Tests

  func testCleanExecution_Succeeds() async throws {
    let transport = MockAntigravityCLITransport()
    let execution = makeExecution(transport: transport)
    execution.start()

    pushInit(on: transport)
    pushToolStep(on: transport, stepIndex: 1, output: "OK")
    pushResult(on: transport, status: "SUCCESS")
    transport.finish()

    var events: [AgentEvent] = []
    for try await envelope in execution.events {
      events.append(envelope.event)
    }

    let hasCompleted = events.contains {
      if case .completed = $0 { return true }
      return false
    }
    let hasFailed = events.contains {
      if case .failed = $0 { return true }
      return false
    }

    XCTAssertTrue(hasCompleted, "Clean execution must emit .completed")
    XCTAssertFalse(hasFailed, "Clean execution must not emit .failed")
  }

  func testIntermediatePermissionDenialFollowedBySuccessfulFollowup_RecoversAndSucceeds() async throws {
    // Stderr contains stale denial evidence from the first step
    let transport = MockAntigravityCLITransport(
      stderr: "Permission denied: native AGY policy requires review; the Bridge MCP command was not run."
    )
    let execution = makeExecution(transport: transport)
    execution.start()

    pushInit(on: transport)
    // Step 1: Intermediate permission denial (e.g. out of bounds CWD)
    pushToolStep(on: transport, stepIndex: 1, isPermissionDenied: true)
    // Step 2: Genuine recovery with subsequent successful tool execution
    pushToolStep(on: transport, stepIndex: 2, output: "Succeeded in project root")
    // Result: Authoritative final SUCCESS
    pushResult(on: transport, status: "SUCCESS")
    transport.finish()

    var events: [AgentEvent] = []
    for try await envelope in execution.events {
      events.append(envelope.event)
    }

    let hasCompleted = events.contains {
      if case .completed = $0 { return true }
      return false
    }
    let hasFailed = events.contains {
      if case .failed = $0 { return true }
      return false
    }
    let hasAutoDenied = events.contains {
      if case .approvalAutomaticallyDenied = $0 { return true }
      return false
    }

    XCTAssertTrue(hasCompleted, "Intermediate denial with genuine recovery must complete successfully")
    XCTAssertFalse(hasFailed, "Intermediate denial with genuine recovery must not fail")
    XCTAssertFalse(hasAutoDenied, "Intermediate denial with genuine recovery must not emit approvalAutomaticallyDenied")
  }

  func testUnresolvedPermissionDenial_NoFollowupTool_FailsClosed() async throws {
    let transport = MockAntigravityCLITransport()
    let execution = makeExecution(transport: transport)
    execution.start()

    pushInit(on: transport)
    // Step 1: Permission denied on tool
    pushToolStep(on: transport, stepIndex: 1, isPermissionDenied: true)
    // No subsequent tool executed; agent terminates turn with SUCCESS string response
    pushResult(on: transport, status: "SUCCESS", response: "I cannot continue due to permissions.")
    transport.finish()

    var events: [AgentEvent] = []
    for try await envelope in execution.events {
      events.append(envelope.event)
    }

    let failureEvent = events.compactMap { event -> (code: String, summary: String)? in
      if case .failed(let code, let summary) = event { return (code, summary) }
      return nil
    }.first

    XCTAssertNotNil(failureEvent, "Unresolved permission denial must fail closed")
    XCTAssertEqual(failureEvent?.code, "antigravity_permission_denied")
  }

  func testPermissionDenialOnFinalTool_FailsClosed() async throws {
    let transport = MockAntigravityCLITransport()
    let execution = makeExecution(transport: transport)
    execution.start()

    pushInit(on: transport)
    // Step 1: Successful tool
    pushToolStep(on: transport, stepIndex: 1, output: "Step 1 OK")
    // Step 2: Final tool is denied
    pushToolStep(on: transport, stepIndex: 2, isPermissionDenied: true)
    pushResult(on: transport, status: "SUCCESS")
    transport.finish()

    var events: [AgentEvent] = []
    for try await envelope in execution.events {
      events.append(envelope.event)
    }

    let failureEvent = events.compactMap { event -> (code: String, summary: String)? in
      if case .failed(let code, let summary) = event { return (code, summary) }
      return nil
    }.first

    XCTAssertNotNil(failureEvent, "Denial on the final tool must fail closed")
    XCTAssertEqual(failureEvent?.code, "antigravity_permission_denied")
  }

  func testIntermediateDenialWithSubsequentDenialAtEnd_FailsClosed() async throws {
    let transport = MockAntigravityCLITransport()
    let execution = makeExecution(transport: transport)
    execution.start()

    pushInit(on: transport)
    // Step 1: Denied
    pushToolStep(on: transport, stepIndex: 1, isPermissionDenied: true)
    // Step 2: Recovered
    pushToolStep(on: transport, stepIndex: 2, output: "OK")
    // Step 3: Denied again
    pushToolStep(on: transport, stepIndex: 3, isPermissionDenied: true)
    pushResult(on: transport, status: "SUCCESS")
    transport.finish()

    var events: [AgentEvent] = []
    for try await envelope in execution.events {
      events.append(envelope.event)
    }

    let failureEvent = events.compactMap { event -> (code: String, summary: String)? in
      if case .failed(let code, let summary) = event { return (code, summary) }
      return nil
    }.first

    XCTAssertNotNil(failureEvent, "Subsequent denial after recovery must fail closed")
    XCTAssertEqual(failureEvent?.code, "antigravity_permission_denied")
  }

  func testIntermediateDenialWithNonSuccessResultStatus_FailsClosed() async throws {
    let transport = MockAntigravityCLITransport()
    let execution = makeExecution(transport: transport)
    execution.start()

    pushInit(on: transport)
    // Step 1: Denied
    pushToolStep(on: transport, stepIndex: 1, isPermissionDenied: true)
    // Step 2: Succeeded
    pushToolStep(on: transport, stepIndex: 2, output: "OK")
    // Result: FAILED status
    pushResult(on: transport, status: "FAILED", response: "Execution crashed")
    transport.finish()

    var events: [AgentEvent] = []
    for try await envelope in execution.events {
      events.append(envelope.event)
    }

    let failureEvent = events.compactMap { event -> (code: String, summary: String)? in
      if case .failed(let code, let summary) = event { return (code, summary) }
      return nil
    }.first

    XCTAssertNotNil(failureEvent, "Non-success result status must fail closed")
    XCTAssertEqual(failureEvent?.code, "antigravity_permission_denied")
  }

  func testIntermediateDenialWithExplicitResultError_FailsClosed() async throws {
    let transport = MockAntigravityCLITransport()
    let execution = makeExecution(transport: transport)
    execution.start()

    pushInit(on: transport)
    pushToolStep(on: transport, stepIndex: 1, isPermissionDenied: true)
    pushToolStep(on: transport, stepIndex: 2, output: "OK")
    // Result: status SUCCESS but explicit permission denied error
    pushResult(on: transport, status: "SUCCESS", error: "permission was denied by user")
    transport.finish()

    var events: [AgentEvent] = []
    for try await envelope in execution.events {
      events.append(envelope.event)
    }

    let failureEvent = events.compactMap { event -> (code: String, summary: String)? in
      if case .failed(let code, let summary) = event { return (code, summary) }
      return nil
    }.first

    XCTAssertNotNil(failureEvent, "Result with explicit permission denied error must fail closed")
    XCTAssertEqual(failureEvent?.code, "antigravity_permission_denied")
  }

  func testUnresolvedStderrDenialWithoutRecovery_FailsClosed() async throws {
    // Process printed permission denied to stderr, but no tool step was denied
    let transport = MockAntigravityCLITransport(
      stderr: "Fatal: permission denied to access requested resource"
    )
    let execution = makeExecution(transport: transport)
    execution.start()

    pushInit(on: transport)
    // No tools run
    pushResult(on: transport, status: "SUCCESS")
    transport.finish()

    var events: [AgentEvent] = []
    for try await envelope in execution.events {
      events.append(envelope.event)
    }

    let failureEvent = events.compactMap { event -> (code: String, summary: String)? in
      if case .failed(let code, let summary) = event { return (code, summary) }
      return nil
    }.first

    XCTAssertNotNil(failureEvent, "Unresolved stderr denial without recovery evidence must fail closed")
    XCTAssertEqual(failureEvent?.code, "antigravity_permission_denied")
  }
}
