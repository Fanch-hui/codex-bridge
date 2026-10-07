import Foundation

public struct AppUpdateStatus: Equatable, Sendable {
  public var phase = "idle"
  public let currentVersion: String
  public var availableVersion: String?
  public var notes: String?
  public var progress: Double?
  public var message: String?
  public var isDeferred = false

  public init(currentVersion: String) {
    self.currentVersion = currentVersion
  }
}

public struct AppUpdateInstallationReadiness: Sendable {
  public let canInstall: Bool
  public let waitingReason: String?

  public init(canInstall: Bool, waitingReason: String? = nil) {
    self.canInstall = canInstall
    self.waitingReason = waitingReason
  }
}

@MainActor
public final class AppUpdateController {
  public private(set) var state: AppUpdateStatus {
    didSet { if oldValue != state { onChange?(state) } }
  }
  public var onChange: (@MainActor (AppUpdateStatus) -> Void)?

  private let client: any AppUpdateClientProtocol
  private let platform: String
  private let architecture: String
  private let kind: String
  private let preparePackage: @MainActor (URL, AppUpdateRelease) async throws -> Void
  private let acquireInstallation: @MainActor () async throws -> AppUpdateInstallationReadiness
  private let installPackage: @MainActor () async throws -> Void
  private let cancelInstallation: @MainActor () async -> Void
  private var operation: Task<Void, Never>?
  private var operationID: UUID?
  private var release: AppUpdateRelease?
  private var didStart = false

  public init(
    currentVersion: String, platform: String, architecture: String, kind: String,
    client: any AppUpdateClientProtocol = AppUpdateClient(),
    preparePackage: @escaping @MainActor (URL, AppUpdateRelease) async throws -> Void,
    acquireInstallation: @escaping @MainActor () async throws -> Bool,
    installPackage: @escaping @MainActor () async throws -> Void,
    cancelInstallation: @escaping @MainActor () async -> Void,
    acquireInstallationStatus: (@MainActor () async throws -> AppUpdateInstallationReadiness)? = nil
  ) {
    state = AppUpdateStatus(currentVersion: currentVersion)
    self.platform = platform
    self.architecture = architecture
    self.kind = kind
    self.client = client
    self.preparePackage = preparePackage
    self.acquireInstallation =
      acquireInstallationStatus ?? {
        AppUpdateInstallationReadiness(canInstall: try await acquireInstallation())
      }
    self.installPackage = installPackage
    self.cancelInstallation = cancelInstallation
  }

  public func start() {
    guard !didStart else { return }
    didStart = true
    check(automatically: true)
  }

  public func check() { check(automatically: false) }

  private func check(automatically: Bool) {
    guard operation == nil, state.phase != "installing" else { return }
    let id = UUID()
    operationID = id
    state.phase = "checking"
    state.message = nil
    state.isDeferred = false
    operation = Task { [weak self] in
      guard let self else { return }
      do {
        let result = try await client.check(
          currentVersion: state.currentVersion, platform: platform,
          architecture: architecture, kind: kind)
        try Task.checkCancellation()
        release = result
        finishOperation(id)
        state.availableVersion = result?.manifest.version
        state.notes = result?.manifest.notes
        state.phase = result == nil ? "upToDate" : "available"
      } catch {
        finishOperation(id)
        if Task.isCancelled {
          restoreAvailableState()
        } else {
          state.phase = automatically ? "idle" : "failed"
          state.message =
            automatically ? nil : AppUpdateFailurePresentation.message(error, phase: "checking")
        }
      }
    }
  }

  public func install() {
    guard operation == nil, let release, state.phase != "installing" else { return }
    let id = UUID()
    operationID = id
    state.phase = "downloading"
    state.progress = 0
    state.message = nil
    state.isDeferred = false
    operation = Task { [weak self] in
      guard let self else { return }
      await performInstallation(release, operationID: id)
    }
  }

  private func performInstallation(_ release: AppUpdateRelease, operationID id: UUID) async {
    var package: URL?
    var failurePhase = "downloading"
    do {
      let downloaded = try await client.download(release) { [weak self] progress in
        Task { @MainActor in
          guard let self, self.operationID == id, self.state.phase == "downloading" else { return }
          self.state.progress = progress
        }
      }
      package = downloaded
      try Task.checkCancellation()
      failurePhase = "verifying"
      state.phase = "verifying"
      state.progress = nil
      try await preparePackage(downloaded, release)
      try Task.checkCancellation()
      failurePhase = "waiting"
      state.phase = "waiting"
      while true {
        let readiness = try await acquireInstallation()
        try Task.checkCancellation()
        if readiness.canInstall { break }
        state.message = readiness.waitingReason ?? "正在等待后台任务、命令和工作区操作完成。"
        try await Task.sleep(for: .seconds(2))
      }
      state.message = nil
      failurePhase = "installing"
      state.phase = "installing"
      try await installPackage()
      // The detached installer owns the staged files after handoff.
      finishOperation(id)
    } catch {
      // Cleanup must release the service lease even when the update task was cancelled.
      await Task { await self.cancelInstallation() }.value
      if let package {
        try? FileManager.default.removeItem(at: package.deletingLastPathComponent())
      }
      finishOperation(id)
      if Task.isCancelled {
        restoreAvailableState()
      } else {
        state.progress = nil
        state.message = AppUpdateFailurePresentation.message(error, phase: failurePhase)
        state.phase = "failed"
      }
    }
  }

  private func finishOperation(_ id: UUID) {
    guard operationID == id else { return }
    operation = nil
    operationID = nil
  }

  private func restoreAvailableState() {
    state.progress = nil
    state.message = nil
    state.isDeferred = false
    state.phase = release == nil ? "idle" : "available"
  }

  public func deferUpdate() {
    guard operation == nil, state.phase == "available" || state.phase == "failed" else { return }
    if state.phase == "failed" {
      release = nil
      state = AppUpdateStatus(currentVersion: state.currentVersion)
      return
    }
    state.isDeferred = true
  }

  public func cancel() {
    guard let operation, state.phase != "installing", state.phase != "cancelling" else { return }
    operation.cancel()
    state.phase = "cancelling"
    state.message = "正在取消更新并清理本次下载文件。"
    state.progress = nil
  }
}
