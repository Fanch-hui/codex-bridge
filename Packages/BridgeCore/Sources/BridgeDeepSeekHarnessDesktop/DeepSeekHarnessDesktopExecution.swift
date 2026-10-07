import BridgeACP
import BridgeAgentCore
import Foundation

actor DeepSeekHarnessDesktopExecution {
  private let request: AgentExecutionRequest
  private let installation: AgentInstallation
  private let controller: DeepSeekHarnessDesktopController
  private var client: DeepSeekHarnessDesktopClient
  private var binding: AgentBinding?
  private var continuation: AsyncThrowingStream<AgentEventEnvelope, any Error>.Continuation?
  private var observing: Task<Void, Never>?
  private var cursor: Int64 = 0
  private var sequence: Int64 = 0
  private var terminal = false
  private var normalizer: DeepSeekHarnessDesktopEventNormalizer?

  init(
    request: AgentExecutionRequest, installation: AgentInstallation,
    controller: DeepSeekHarnessDesktopController, client: DeepSeekHarnessDesktopClient
  ) {
    self.request = request
    self.installation = installation
    self.controller = controller
    self.client = client
  }

  func start() async throws -> AgentExecutionHandle {
    guard let runtime = request.runtimeBinding else {
      throw AgentRuntimeError.invalidRequest("dsh.desktop.runtimeBinding")
    }
    var params: [String: ACPJSONValue] = [
      "requestID": .string(runtime.requestID), "projectPath": .string(request.projectRoot),
      "text": .string(request.prompt), "accessMode": .string("full"),
    ]
    if let sessionID = request.requestedSessionID { params["sessionID"] = .string(sessionID) }
    if let model = request.model { params["modelID"] = .string(model) }
    if let effort = request.effort { params["effort"] = .string(effort) }
    let result = try await Task { try await self.startResponse(params: params, runtime: runtime) }
      .value
    if Task.isCancelled {
      try await Task { try await self.confirmStartCancellation(runtime: runtime) }.value
      throw CancellationError()
    }
    guard result["requestID"]?.stringValue == runtime.requestID,
      let sessionID = result["sessionID"]?.stringValue,
      request.requestedSessionID.map({ $0 == sessionID }) ?? true
    else { throw AgentRuntimeError.sessionMismatch }
    let binding = try AgentBinding(
      providerID: installation.providerID, installationID: installation.id,
      providerSessionID: sessionID, providerRunID: runtime.requestID)
    self.binding = binding
    normalizer = DeepSeekHarnessDesktopEventNormalizer(request: request, binding: binding)
    let stream = AsyncThrowingStream<AgentEventEnvelope, any Error>.makeStream(
      bufferingPolicy: .bufferingOldest(1_024))
    continuation = stream.continuation
    observing = Task { await self.observe() }
    return AgentExecutionHandle(
      taskID: request.taskID, binding: binding,
      capabilities: DeepSeekHarnessDesktopProvider.snapshot, events: stream.stream,
      control: AgentExecutionControl(
        interrupt: { try await self.cancel() },
        shutdown: { await self.shutdown() },
        resolveApproval: { id, option in
          try await self.answer(
            id: id,
            answer: .object([
              "decision": .string(option == "allow_once" ? "allow" : "reject")
            ]))
        },
        resolveUserInput: { id, response in
          try await self.userAnswer(id: id, response: response)
        }))
  }

  private func startResponse(params: [String: ACPJSONValue], runtime: AgentRuntimeBinding)
    async throws -> ACPJSONValue
  {
    let original = client.descriptor
    while true {
      do {
        let result = try await client.call("run/start", params: params)
        return result
      } catch let error as DeepSeekHarnessDesktopRPCError { throw error } catch {
        if error is CancellationError { throw error }
        guard original.isRunning else { throw AgentRuntimeError.processUnavailable }
        // A missing start receipt does not establish that no native execution was admitted.
        try? await Task.detached { try await Task.sleep(for: .milliseconds(500)) }.value
        await controller.reset(installation)
        do {
          let replacement = try await controller.client(installation, profileID: runtime.profileID)
          guard replacement.descriptor.instanceID == original.instanceID else {
            throw AgentRuntimeError.processUnavailable
          }
          client = replacement
          try await controller.authorizeProject(request.projectRoot, client: client)
        } catch {
          guard original.isRunning else { throw AgentRuntimeError.processUnavailable }
          continue
        }
      }
    }
  }

  private func confirmStartCancellation(runtime: AgentRuntimeBinding) async throws {
    let original = client.descriptor
    while original.isRunning {
      do {
        let result = try await client.call(
          "run/cancel", params: ["requestID": .string(runtime.requestID)])
        if ["completed", "failed", "cancelled"].contains(result["status"]?.stringValue ?? "") {
          return
        }
      } catch {
        if let rpc = error as? DeepSeekHarnessDesktopRPCError, rpc.code == "run_not_found" {
          return
        }
        await controller.reset(installation)
        if let replacement = try? await controller.client(
          installation, profileID: runtime.profileID),
          replacement.descriptor.instanceID == original.instanceID
        {
          client = replacement
        }
      }
      try await Task.sleep(for: .milliseconds(500))
    }
  }

  private func observe() async {
    guard let runtime = request.runtimeBinding else { return }
    while !terminal {
      do {
        let value = try await client.call(
          "run/observe",
          params: [
            "requestID": .string(runtime.requestID), "cursor": .integer(cursor),
          ])
        do { try consume(value, requestID: runtime.requestID) } catch {
          let state = try await client.call(
            "run/cancel",
            params: [
              "requestID": .string(runtime.requestID)
            ])
          guard ["completed", "failed", "cancelled"].contains(state["status"]?.stringValue ?? "")
          else {
            throw error
          }
          finish(.failed(code: "desktop_event_invalid", summary: "DSH 原生事件无法解析。"))
        }
        if !terminal { try await Task.sleep(for: .milliseconds(200)) }
      } catch {
        guard !terminal else { return }
        if !client.descriptor.isRunning {
          finish(.failed(code: "desktop_host_exited", summary: "DSH Desktop Host 已退出。"))
          return
        }
        // The task and write lease remain active until its owner confirms a terminal state.
        try? await Task.sleep(for: .milliseconds(500))
        await controller.reset(installation)
        do {
          let replacement = try await controller.client(installation, profileID: runtime.profileID)
          guard replacement.descriptor.instanceID == client.descriptor.instanceID else {
            finish(.failed(code: "desktop_host_restarted", summary: "DSH Desktop Host 已重新启动。"))
            return
          }
          client = replacement
        } catch { continue }
      }
    }
  }

  private func consume(_ value: ACPJSONValue, requestID: String) throws {
    guard value["requestID"]?.stringValue == requestID,
      value["sessionID"]?.stringValue == binding?.providerSessionID,
      let events = value["events"]?.arrayValue
    else {
      throw AgentRuntimeError.malformedEvent("dsh_desktop_observation")
    }
    for event in events {
      guard event["requestID"]?.stringValue == requestID,
        let position = event["cursor"]?.intValue, position > cursor
      else { continue }
      guard let mapped = try normalizer?.normalize(event) else {
        cursor = Int64(position)
        continue
      }
      cursor = Int64(position)
      if Self.isTerminal(mapped) {
        finish(mapped)
        return
      }
      emit(mapped)
    }
    if let next = value["cursor"]?.intValue { cursor = max(cursor, Int64(next)) }
    switch value["status"]?.stringValue {
    case "completed":
      finish(.completed(summary: normalizer?.summary ?? "", stopReason: "completed"))
    case "cancelled": finish(.interrupted)
    case "failed":
      finish(
        .failed(
          code: "desktop_run_failed",
          summary: value["message"]?.stringValue ?? "DSH 原生任务执行失败。"))
    default: break
    }
  }

  private func cancel() async throws {
    guard !terminal, let runtime = request.runtimeBinding else { return }
    let value = try await client.call(
      "run/cancel", params: ["requestID": .string(runtime.requestID)])
    if value["status"]?.stringValue == "cancelled" { finish(.interrupted) }
  }

  private func shutdown() async {
    try? await cancel()
    await observing?.value
  }

  private func answer(id: String, answer: ACPJSONValue) async throws {
    guard !terminal, let runtime = request.runtimeBinding else {
      throw AgentRuntimeError.approvalUnavailable(id)
    }
    _ = try await client.call(
      "interaction/answer",
      params: [
        "requestID": .string(runtime.requestID), "interactionID": .string(id), "answer": answer,
      ])
  }

  private func userAnswer(id: String, response: AgentUserInputResponse) async throws {
    guard let normalizer else { throw AgentRuntimeError.approvalUnavailable(id) }
    try await answer(id: id, answer: normalizer.answer(inputID: id, response: response))
  }

  private func emit(_ event: AgentEvent) {
    guard let binding else { return }
    sequence += 1
    guard
      let envelope = try? AgentEventEnvelope(
        taskID: request.taskID, providerID: binding.providerID,
        providerSessionID: binding.providerSessionID, providerRunID: binding.providerRunID,
        providerSequence: sequence, event: event)
    else { return }
    continuation?.yield(envelope)
  }

  private func finish(_ event: AgentEvent) {
    guard !terminal else { return }
    terminal = true
    emit(event)
    continuation?.finish()
    continuation = nil
  }

  private static func isTerminal(_ event: AgentEvent) -> Bool {
    switch event {
    case .completed, .failed, .interrupted: true
    default: false
    }
  }
}
