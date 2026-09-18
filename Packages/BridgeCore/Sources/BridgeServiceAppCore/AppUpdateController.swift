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
  private let acquireInstallation: @MainActor () async throws -> Bool
  private let installPackage: @MainActor () async throws -> Void
  private let cancelInstallation: @MainActor () async -> Void
  private var operation: Task<Void, Never>?
  private var release: AppUpdateRelease?
  private var didStart = false

  public init(
    currentVersion: String, platform: String, architecture: String, kind: String,
    client: any AppUpdateClientProtocol = AppUpdateClient(),
    preparePackage: @escaping @MainActor (URL, AppUpdateRelease) async throws -> Void,
    acquireInstallation: @escaping @MainActor () async throws -> Bool,
    installPackage: @escaping @MainActor () async throws -> Void,
    cancelInstallation: @escaping @MainActor () async -> Void
  ) {
    state = AppUpdateStatus(currentVersion: currentVersion)
    self.platform = platform
    self.architecture = architecture
    self.kind = kind
    self.client = client
    self.preparePackage = preparePackage
    self.acquireInstallation = acquireInstallation
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
    state.phase = "checking"
    state.message = nil
    state.isDeferred = false
    operation = Task { [weak self] in
      guard let self else { return }
      defer { operation = nil }
      do {
        let result = try await client.check(
          currentVersion: state.currentVersion, platform: platform,
          architecture: architecture, kind: kind)
        try Task.checkCancellation()
        release = result
        state.availableVersion = result?.manifest.version
        state.notes = result?.manifest.notes
        state.phase = result == nil ? "upToDate" : "available"
      } catch {
        guard !Task.isCancelled else { return }
        state.phase = automatically ? "idle" : "failed"
        state.message = automatically ? nil : error.localizedDescription
      }
    }
  }

  public func install() {
    guard operation == nil, let release, state.phase != "installing" else { return }
    state.phase = "downloading"
    state.progress = 0
    state.message = nil
    state.isDeferred = false
    operation = Task { [weak self] in
      guard let self else { return }
      defer { operation = nil }
      var package: URL?
      do {
        let downloaded = try await client.download(release) { [weak self] progress in
          Task { @MainActor in
            guard let self, self.state.phase == "downloading" else { return }
            self.state.progress = progress
          }
        }
        package = downloaded
        try Task.checkCancellation()
        try await preparePackage(downloaded, release)
        state.phase = "waiting"
        state.progress = nil
        while try await !acquireInstallation() {
          try await Task.sleep(for: .seconds(2))
        }
        try Task.checkCancellation()
        state.phase = "installing"
        try await installPackage()
        // The detached installer owns the staged files after handoff.
      } catch {
        await cancelInstallation()
        if let package {
          try? FileManager.default.removeItem(at: package.deletingLastPathComponent())
        }
        guard !Task.isCancelled else { return }
        state.phase = "failed"
        state.progress = nil
        state.message = error.localizedDescription
      }
    }
  }

  public func deferUpdate() {
    guard operation == nil, state.phase == "available" || state.phase == "failed" else { return }
    state.isDeferred = true
  }

  public func cancel() {
    guard state.phase != "installing" else { return }
    operation?.cancel()
  }
}
