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
    self.stderrSnapshot = BoundedProcessOutput(
      head: stderr,
      tail: "",
      byteCount: stderr.utf8.count,
      truncated: false
    )
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
      {"event":"init","conversation_id":"\(sessionID)","init":{"cwd":"\(escapedCwd)","tools":["bridge_run_command","read_file"],"permission_mode":"always-proceed"}}
      """)
  }

  private func pushToolStep(
    on transport: MockAntigravityCLITransport,
    sessionID: String = "session-1",
    stepIndex: Int,
    toolName: String = "bridge_run_command",
    command: String? = nil,
    path: String? = nil,
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
    var paramsParts: [String] = []
    if let command {
      paramsParts.append("\"command\":\"\(jsonEscape(command))\"")
    }
    if let path {
      paramsParts.append("\"path\":\"\(jsonEscape(path))\"")
    }
    let paramsPart = paramsParts.isEmpty ? "" : ",\"parameters\":{\(paramsParts.joined(separator: ","))}"

    let escapedToolName = jsonEscape(toolName)
    transport.pushFrame("""
      {"event":"step_update","step_update":{"conversation_id":"\(sessionID)","step_index":\(stepIndex),"state":"\(state)","step_type":"tool","tool_name":"\(escapedToolName)","tool_info":{"name":"\(escapedToolName)"\(paramsPart)\(errorPart)\(outputPart)}}}
      """)
  }

  private func pushAnonymousStep(
    on transport: MockAntigravityCLITransport,
    sessionID: String = "session-1",
    stepIndex: Int,
    errorMessage: String = "Operation was denied by local policy"
  ) {
    transport.pushFrame("""
      {"event":"step_update","step_update":{"conversation_id":"\(sessionID)","step_index":\(stepIndex),"state":"ACTIVE","step_type":"agent_response","error":{"message":"\(jsonEscape(errorMessage))"}}}
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
    await execution.start()

    pushInit(on: transport)
    pushToolStep(on: transport, stepIndex: 1, command: "git status", output: "OK")
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

  func testIntermediatePermissionDenialFollowedBySameOperationRecovery_RecoversAndSucceeds() async throws {
    // Stderr contains stale denial evidence from the first step
    let transport = MockAntigravityCLITransport(
      stderr: "Permission denied: native AGY policy requires review; the Bridge MCP command was not run."
    )
    let execution = makeExecution(transport: transport)
    await execution.start()

    pushInit(on: transport)
    // Step 1: Intermediate permission denial on git status
    pushToolStep(
      on: transport,
      stepIndex: 1,
      toolName: "bridge_run_command",
      command: "git status",
      isPermissionDenied: true
    )
    // Step 2: Genuine recovery with subsequent successful execution of the SAME operation
    pushToolStep(
      on: transport,
      stepIndex: 2,
      toolName: "bridge_run_command",
      command: "git status",
      output: "Succeeded in project root"
    )
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

    XCTAssertTrue(hasCompleted, "Intermediate denial with genuine same-operation recovery must complete successfully")
    XCTAssertFalse(hasFailed, "Intermediate denial with genuine recovery must not fail")
    XCTAssertFalse(hasAutoDenied, "Intermediate denial with genuine recovery must not emit approvalAutomaticallyDenied")
  }

  func testUnrelatedSuccessfulToolAfterDenial_FailsClosed() async throws {
    let transport = MockAntigravityCLITransport()
    let execution = makeExecution(transport: transport)
    await execution.start()

    pushInit(on: transport)
    // Step 1: Permission denied on bridge_run_command
    pushToolStep(
      on: transport,
      stepIndex: 1,
      toolName: "bridge_run_command",
      command: "git push origin main",
      isPermissionDenied: true
    )
    // Step 2: Unrelated tool (read_file) succeeds
    pushToolStep(
      on: transport,
      stepIndex: 2,
      toolName: "read_file",
      path: "README.md",
      output: "# Documentation"
    )
    // Result: Final status SUCCESS (agent completed turn after reading file)
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

    XCTAssertNotNil(failureEvent, "Unrelated successful tool must NOT clear permission denial - must fail closed")
    XCTAssertEqual(failureEvent?.code, "antigravity_permission_denied")
    let hasCompleted = events.contains {
      if case .completed = $0 { return true }
      return false
    }
    XCTAssertFalse(hasCompleted, "Must not emit .completed when unresolved denial exists")
  }

  func testDifferentCommandSuccessfulAfterDenial_FailsClosed() async throws {
    let transport = MockAntigravityCLITransport()
    let execution = makeExecution(transport: transport)
    await execution.start()

    pushInit(on: transport)
    // Step 1: Denied command
    pushToolStep(
      on: transport,
      stepIndex: 1,
      toolName: "bridge_run_command",
      command: "pytest tests/security",
      isPermissionDenied: true
    )
    // Step 2: Different command succeeds (not evidence that original command was remediated)
    pushToolStep(
      on: transport,
      stepIndex: 2,
      toolName: "bridge_run_command",
      command: "echo done",
      output: "done"
    )
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

    XCTAssertNotNil(failureEvent, "Different successful command must NOT clear permission denial - must fail closed")
    XCTAssertEqual(failureEvent?.code, "antigravity_permission_denied")
    let hasCompleted = events.contains {
      if case .completed = $0 { return true }
      return false
    }
    XCTAssertFalse(hasCompleted, "Must not emit .completed when different command succeeded")
  }

  func testMultipleDeniedOperations_PartialRecovery_FailsClosed() async throws {
    let transport = MockAntigravityCLITransport()
    let execution = makeExecution(transport: transport)
    await execution.start()

    pushInit(on: transport)
    // Step 1: cmd1 denied
    pushToolStep(
      on: transport,
      stepIndex: 1,
      toolName: "bridge_run_command",
      command: "cmd1",
      isPermissionDenied: true
    )
    // Step 2: cmd2 denied
    pushToolStep(
      on: transport,
      stepIndex: 2,
      toolName: "bridge_run_command",
      command: "cmd2",
      isPermissionDenied: true
    )
    // Step 3: cmd2 retried and succeeds (cmd1 remains unresolved!)
    pushToolStep(
      on: transport,
      stepIndex: 3,
      toolName: "bridge_run_command",
      command: "cmd2",
      output: "cmd2 OK"
    )
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

    XCTAssertNotNil(failureEvent, "Partial recovery with remaining unresolved denial must fail closed")
    XCTAssertEqual(failureEvent?.code, "antigravity_permission_denied")
    let hasCompleted = events.contains {
      if case .completed = $0 { return true }
      return false
    }
    XCTAssertFalse(hasCompleted, "Must not emit .completed on partial recovery")
  }

  func testRepeatedDenialAfterRecovery_FailsClosed() async throws {
    let transport = MockAntigravityCLITransport()
    let execution = makeExecution(transport: transport)
    await execution.start()

    pushInit(on: transport)
    // Step 1: Denied
    pushToolStep(
      on: transport,
      stepIndex: 1,
      toolName: "bridge_run_command",
      command: "git status",
      isPermissionDenied: true
    )
    // Step 2: Recovered
    pushToolStep(
      on: transport,
      stepIndex: 2,
      toolName: "bridge_run_command",
      command: "git status",
      output: "OK"
    )
    // Step 3: Denied again on another command
    pushToolStep(
      on: transport,
      stepIndex: 3,
      toolName: "bridge_run_command",
      command: "git push",
      isPermissionDenied: true
    )
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
    let hasCompleted = events.contains {
      if case .completed = $0 { return true }
      return false
    }
    XCTAssertFalse(hasCompleted, "Must not emit .completed on repeated denial")
  }

  func testUnresolvedPermissionDenial_NoFollowupTool_FailsClosed() async throws {
    let transport = MockAntigravityCLITransport()
    let execution = makeExecution(transport: transport)
    await execution.start()

    pushInit(on: transport)
    // Step 1: Permission denied on tool
    pushToolStep(
      on: transport,
      stepIndex: 1,
      toolName: "bridge_run_command",
      command: "rm -rf /",
      isPermissionDenied: true
    )
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
    let hasCompleted = events.contains {
      if case .completed = $0 { return true }
      return false
    }
    XCTAssertFalse(hasCompleted, "Must not emit .completed on unresolved denial")
  }

  func testPermissionDenialOnFinalTool_FailsClosed() async throws {
    let transport = MockAntigravityCLITransport()
    let execution = makeExecution(transport: transport)
    await execution.start()

    pushInit(on: transport)
    // Step 1: Successful tool
    pushToolStep(
      on: transport,
      stepIndex: 1,
      toolName: "bridge_run_command",
      command: "git status",
      output: "Step 1 OK"
    )
    // Step 2: Final tool is denied
    pushToolStep(
      on: transport,
      stepIndex: 2,
      toolName: "bridge_run_command",
      command: "git commit -m initial",
      isPermissionDenied: true
    )
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
    let hasCompleted = events.contains {
      if case .completed = $0 { return true }
      return false
    }
    XCTAssertFalse(hasCompleted, "Must not emit .completed when final tool is denied")
  }

  func testIntermediateDenialWithNonSuccessResultStatus_FailsClosed() async throws {
    let transport = MockAntigravityCLITransport()
    let execution = makeExecution(transport: transport)
    await execution.start()

    pushInit(on: transport)
    // Step 1: Denied
    pushToolStep(
      on: transport,
      stepIndex: 1,
      toolName: "bridge_run_command",
      command: "git status",
      isPermissionDenied: true
    )
    // Step 2: Succeeded with same operation
    pushToolStep(
      on: transport,
      stepIndex: 2,
      toolName: "bridge_run_command",
      command: "git status",
      output: "OK"
    )
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
    let hasCompleted = events.contains {
      if case .completed = $0 { return true }
      return false
    }
    XCTAssertFalse(hasCompleted, "Must not emit .completed on failed status")
  }

  func testIntermediateDenialWithExplicitResultError_FailsClosed() async throws {
    let transport = MockAntigravityCLITransport()
    let execution = makeExecution(transport: transport)
    await execution.start()

    pushInit(on: transport)
    pushToolStep(
      on: transport,
      stepIndex: 1,
      toolName: "bridge_run_command",
      command: "git status",
      isPermissionDenied: true
    )
    pushToolStep(
      on: transport,
      stepIndex: 2,
      toolName: "bridge_run_command",
      command: "git status",
      output: "OK"
    )
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
    let hasCompleted = events.contains {
      if case .completed = $0 { return true }
      return false
    }
    XCTAssertFalse(hasCompleted, "Must not emit .completed when result has explicit error")
  }

  func testUnresolvedStderrDenialWithoutRecovery_FailsClosed() async throws {
    // Process printed permission denied to stderr, but no tool step was denied
    let transport = MockAntigravityCLITransport(
      stderr: "Fatal: permission denied to access requested resource"
    )
    let execution = makeExecution(transport: transport)
    await execution.start()

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
    let hasCompleted = events.contains {
      if case .completed = $0 { return true }
      return false
    }
    XCTAssertFalse(hasCompleted, "Must not emit .completed on unresolved stderr denial")
  }

  func testAnonymousPermissionDenial_FailsClosed() async throws {
    let transport = MockAntigravityCLITransport()
    let execution = makeExecution(transport: transport)
    await execution.start()

    pushInit(on: transport)
    // Step 1: Anonymous denial (no tool context attached)
    pushAnonymousStep(on: transport, stepIndex: 1, errorMessage: "Operation was denied by local policy")
    // Step 2: Some tool succeeds
    pushToolStep(
      on: transport,
      stepIndex: 2,
      toolName: "bridge_run_command",
      command: "git status",
      output: "OK"
    )
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

    XCTAssertNotNil(failureEvent, "Anonymous denial cannot be proven remediated and must fail closed")
    XCTAssertEqual(failureEvent?.code, "antigravity_permission_denied")
    let hasCompleted = events.contains {
      if case .completed = $0 { return true }
      return false
    }
    XCTAssertFalse(hasCompleted, "Must not emit .completed on anonymous denial")
  }

  func testAmbiguousToolDenialWithoutTarget_FailsClosed() async throws {
    let transport = MockAntigravityCLITransport()
    let execution = makeExecution(transport: transport)
    await execution.start()

    pushInit(on: transport)
    // Step 1: Tool denied with no extractable target or arguments
    pushToolStep(
      on: transport,
      stepIndex: 1,
      toolName: "custom_ambiguous_tool",
      isPermissionDenied: true
    )
    // Step 2: Same tool name succeeds without target or arguments
    pushToolStep(
      on: transport,
      stepIndex: 2,
      toolName: "custom_ambiguous_tool",
      output: "OK"
    )
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

    XCTAssertNotNil(failureEvent, "Ambiguous denial without target evidence must fail closed")
    XCTAssertEqual(failureEvent?.code, "antigravity_permission_denied")
    let hasCompleted = events.contains {
      if case .completed = $0 { return true }
      return false
    }
    XCTAssertFalse(hasCompleted, "Must not emit .completed on ambiguous denial")
  }

  func testRepeatedDenialOfSameCommandAfterRecovery_FailsClosed() async throws {
    let transport = MockAntigravityCLITransport()
    let execution = makeExecution(transport: transport)
    await execution.start()

    pushInit(on: transport)
    // Step 1: git push denied
    pushToolStep(
      on: transport,
      stepIndex: 1,
      toolName: "bridge_run_command",
      command: "git push origin main",
      isPermissionDenied: true
    )
    // Step 2: git push retried and succeeds (recovered)
    pushToolStep(
      on: transport,
      stepIndex: 2,
      toolName: "bridge_run_command",
      command: "git push origin main",
      output: "Pushed successfully"
    )
    // Step 3: git push executed again and DENIED
    pushToolStep(
      on: transport,
      stepIndex: 3,
      toolName: "bridge_run_command",
      command: "git push origin main",
      isPermissionDenied: true
    )
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

    XCTAssertNotNil(failureEvent, "Repeated denial of same command after initial recovery must fail closed")
    XCTAssertEqual(failureEvent?.code, "antigravity_permission_denied")
    let hasCompleted = events.contains {
      if case .completed = $0 { return true }
      return false
    }
    XCTAssertFalse(hasCompleted, "Must not emit .completed when final state is denied")
  }
}
