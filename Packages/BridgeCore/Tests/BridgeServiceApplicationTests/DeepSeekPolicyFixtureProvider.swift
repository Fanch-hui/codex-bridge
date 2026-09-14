import BridgeAgentCore
import BridgeDomain
import Foundation

final class DeepSeekPolicyFixtureProvider: AgentProvider, @unchecked Sendable {
  private struct Run {
    let continuation: AsyncThrowingStream<AgentEventEnvelope, any Error>.Continuation
  }

  let descriptor: AgentProviderDescriptor
  private let lock = NSLock()
  private var runs: [TaskID: Run] = [:]
  private(set) var startedRequests: [AgentExecutionRequest] = []

  let supportsContinuation: Bool

  init(supportsContinuation: Bool = false) throws {
    self.supportsContinuation = supportsContinuation
    descriptor = try AgentProviderDescriptor(
      providerID: .deepSeekHarness,
      displayName: "DeepSeek Harness",
      adapterRevision: 1
    )
  }

  func probe(_ request: AgentProbeRequest) async -> AgentProbeResult {
    guard
      let installation = try? AgentInstallation(
        id: request.installation.id,
        providerID: .deepSeekHarness,
        executablePath: request.installation.executablePath,
        version: "0.1.5-rc.2",
        protocolRevision: "1"
      )
    else {
      return AgentProbeResult(
        installation: request.installation,
        available: false,
        capabilities: .empty,
        unavailableReason: "The fixture installation is invalid."
      )
    }
    var capabilities: Set<AgentCapability> = [
      .sessionCreate, .interrupt, .steer, .textDelta, .toolLifecycle, .workspaceRead,
      .workspaceWriteInPlace, .oneShotApproval, .structuredApprovalPayload, .modelSelection,
      .effortSelection, .shell, .webSearch, .webFetch, .codeExecution, .subagents, .workflow,
      .skills,
    ]
    if supportsContinuation { capabilities.insert(.sessionContinue) }
    return AgentProbeResult(
      installation: installation,
      available: true,
      capabilities: AgentCapabilitySnapshot(
        advertised: capabilities,
        observed: capabilities,
        enforced: capabilities
      )
    )
  }

  func models(
    installation _: AgentInstallation,
    projectRoot _: String?,
    selectedModelID: String?
  ) async throws -> [AgentModelDescriptor] {
    if let selectedModelID, selectedModelID != "private-backend/model-v1" {
      throw AgentRuntimeError.modelUnavailable(selectedModelID)
    }
    return try [
      AgentModelDescriptor(
        id: "private-backend/model-v1",
        displayName: "Private Backend Model V1",
        supportedReasoningEfforts: ["off", "low", "high", "max"],
        defaultReasoningEffort: "high"
      )
    ]
  }

  func start(
    _ request: AgentExecutionRequest,
    installation: AgentInstallation
  ) async throws -> AgentExecutionHandle {
    let stream = register(request.taskID)
    recordStarted(request)
    let binding = try AgentBinding(
      providerID: .deepSeekHarness,
      installationID: installation.id,
      providerSessionID: "sess-\(request.taskID.rawValue)",
      providerRunID: "run-\(request.taskID.rawValue)"
    )
    var capabilities: Set<AgentCapability> = [
      .sessionCreate, .interrupt, .steer, .textDelta, .toolLifecycle, .workspaceRead,
      .workspaceWriteInPlace, .oneShotApproval, .structuredApprovalPayload, .modelSelection,
      .effortSelection, .shell, .webSearch, .webFetch, .codeExecution, .subagents, .workflow,
      .skills,
    ]
    if supportsContinuation { capabilities.insert(.sessionContinue) }
    return AgentExecutionHandle(
      taskID: request.taskID,
      binding: binding,
      capabilities: AgentCapabilitySnapshot(
        advertised: capabilities,
        observed: capabilities,
        enforced: capabilities
      ),
      events: stream,
      control: AgentExecutionControl(
        interrupt: { [weak self] in self?.finish(taskID: request.taskID) },
        shutdown: { [weak self] in self?.finish(taskID: request.taskID) }
      )
    )
  }

  private func recordStarted(_ request: AgentExecutionRequest) {
    lock.lock()
    startedRequests.append(request)
    lock.unlock()
  }

  func complete(taskID: TaskID) {
    lock.lock()
    let run = runs[taskID]
    lock.unlock()
    let envelope = try? AgentEventEnvelope(
      taskID: taskID,
      providerID: .deepSeekHarness,
      providerSessionID: "sess-\(taskID.rawValue)",
      providerRunID: "run-\(taskID.rawValue)",
      providerSequence: 0,
      event: .completed(summary: "Skill run complete.", stopReason: nil)
    )
    if let envelope { run?.continuation.yield(envelope) }
    run?.continuation.finish()
  }

  private func register(_ taskID: TaskID)
    -> AsyncThrowingStream<AgentEventEnvelope, any Error>
  {
    lock.lock()
    defer { lock.unlock() }
    var continuationRef: AsyncThrowingStream<AgentEventEnvelope, any Error>.Continuation!
    let stream = AsyncThrowingStream<AgentEventEnvelope, any Error>(
      bufferingPolicy: .unbounded
    ) { continuationRef = $0 }
    runs[taskID] = Run(continuation: continuationRef)
    return stream
  }

  private func finish(taskID: TaskID) {
    lock.lock()
    let run = runs[taskID]
    lock.unlock()
    run?.continuation.finish()
  }
}
