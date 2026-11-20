import BridgeServiceApplication
import BridgeServiceCore
import Foundation

public struct ServiceApplicationModeStatus: Sendable, Equatable {
  public let mode: ServiceApplicationMode
  public let transition: String?
  public let error: String?
}

/// Coordinates the admission gate with the persisted mode and the workbench process.
public actor ServiceApplicationModeController {
  private let settings: ServiceSettings
  private let application: BridgeServiceApplication
  private let workbench: ServiceEmbeddedDSHController
  private var mode = ServiceApplicationMode.full
  private var initialized = false
  private var initialization: Task<ServiceApplicationMode, any Error>?
  private var transitionID: UUID?
  private var gateTask: Task<Void, Never>?
  private var transitionTask: Task<Void, Never>?
  private var changing = false
  private var stopped = false
  private var changeWaiters: [CheckedContinuation<Void, Never>] = []
  private var failure: String?

  public init(
    settings: ServiceSettings, application: BridgeServiceApplication,
    embeddedDSH: ServiceEmbeddedDSHController
  ) {
    self.settings = settings
    self.application = application
    self.workbench = embeddedDSH
  }

  /// Call before starting the task queue and workbench recovery.
  public func initialize() async throws {
    guard !initialized else { return }
    let task: Task<ServiceApplicationMode, any Error>
    if let initialization {
      task = initialization
    } else {
      task = Task {
        let saved = try await settings.applicationMode()
        await application.setLightweightAdmission(saved == .lite)
        return saved
      }
      initialization = task
    }
    do {
      let saved = try await task.value
      if !initialized {
        mode = saved
        initialized = true
      }
      initialization = nil
    } catch {
      initialization = nil
      throw error
    }
  }

  public func status() async throws -> ServiceApplicationModeStatus {
    try await initialize()
    return currentStatus()
  }

  public func delegationEnabled() async -> Bool {
    guard initialized else { return false }
    return mode == .full && transitionID == nil && !changing && !stopped
  }

  @discardableResult
  public func setMode(_ target: ServiceApplicationMode) async throws
    -> ServiceApplicationModeStatus
  {
    try await initialize()
    guard !stopped else { throw CancellationError() }
    guard !changing else { throw WorkbenchAvailabilityError.busy }
    if target == .full, transitionID != nil { return try await cancel() }
    guard transitionID == nil else {
      guard target == .lite else { throw WorkbenchAvailabilityError.busy }
      return currentStatus()
    }
    guard mode != target else { return currentStatus() }
    failure = nil

    if target == .full {
      changing = true
      defer { finishChanging() }
      try await workbench.exitLightweightMode()
      try checkRunning()
      await application.setLightweightAdmission(false)
      try checkRunning()
      await application.startTaskQueueProcessor()
      try checkRunning()
      await workbench.resumeWorkbenchRecovery()
      mode = .full
      return currentStatus()
    }

    let id = UUID()
    transitionID = id
    let gate = Task { await application.beginLightweightTransition() }
    gateTask = gate
    await gate.value
    guard transitionID == id else { return currentStatus() }
    gateTask = nil
    transitionTask = Task { await self.runTransition(id: id) }
    return currentStatus()
  }

  @discardableResult
  public func cancel() async throws -> ServiceApplicationModeStatus {
    guard !stopped else { throw CancellationError() }
    guard !changing else { throw WorkbenchAvailabilityError.busy }
    guard let id = transitionID else { return currentStatus() }
    changing = true
    defer { finishChanging() }
    transitionID = nil
    transitionTask?.cancel()
    await gateTask?.value
    await transitionTask?.value
    gateTask = nil
    transitionTask = nil

    do {
      let saved = try await settings.applicationMode()
      try checkRunning()
      if saved == .lite { try await workbench.exitLightweightMode() }
      try checkRunning()
      await application.setLightweightAdmission(false)
      try checkRunning()
      await application.startTaskQueueProcessor()
      try checkRunning()
      await workbench.resumeWorkbenchRecovery()
      mode = .full
      failure = nil
      return currentStatus()
    } catch {
      if !stopped {
        transitionID = id
        failure = "取消切换失败，请重试。"
      }
      throw error
    }
  }

  public func shutdown() async {
    guard !stopped else { return }
    stopped = true
    transitionID = nil
    transitionTask?.cancel()
    await gateTask?.value
    await transitionTask?.value
    gateTask = nil
    transitionTask = nil
    if changing {
      await withCheckedContinuation { changeWaiters.append($0) }
    }
  }

  private func finishChanging() {
    changing = false
    let waiters = changeWaiters
    changeWaiters.removeAll()
    for waiter in waiters { waiter.resume() }
  }

  private func checkRunning() throws {
    guard !stopped else { throw CancellationError() }
  }

  private func currentStatus() -> ServiceApplicationModeStatus {
    ServiceApplicationModeStatus(
      mode: mode, transition: transitionID == nil ? nil : "waiting", error: failure)
  }

  private func runTransition(id: UUID) async {
    do {
      while transitionID == id {
        try Task.checkCancellation()
        if try await application.sealLightweightTransitionIfIdle() {
          do {
            try Task.checkCancellation()
            try await workbench.enterLightweightMode()
            await application.stopTaskQueueProcessor()
            await application.setLightweightAdmission(true)
            guard transitionID == id else { return }
            mode = .lite
            transitionID = nil
            transitionTask = nil
            return
          } catch WorkbenchAvailabilityError.busy {
            await application.resumeLightweightTransition()
          }
        }
        try await Task.sleep(for: .milliseconds(500))
      }
    } catch is CancellationError {
      return
    } catch {
      guard transitionID == id else { return }
      await application.setLightweightAdmission(false)
      await workbench.resumeWorkbenchRecovery()
      transitionID = nil
      transitionTask = nil
      failure = "轻量模式切换失败，请检查工作台状态后重试。"
    }
  }
}
