import BridgeIPC
import Foundation

public struct WorkbenchSettingsStatus: Equatable, Sendable {
  public var enabled: Bool?
  public var isChanging = false
  public var errorMessage: String?

  public init() {}
}

@MainActor
public final class WorkbenchSettingsController {
  public private(set) var state = WorkbenchSettingsStatus() {
    didSet { if oldValue != state { onChange() } }
  }

  private let read: @MainActor () async throws -> IPCWorkbenchSettings
  private let write: @MainActor (Bool) async throws -> IPCWorkbenchSettings
  private let onChange: @MainActor () -> Void
  private var generation: UInt64 = 0

  public init(
    read: @escaping @MainActor () async throws -> IPCWorkbenchSettings,
    write: @escaping @MainActor (Bool) async throws -> IPCWorkbenchSettings,
    onChange: @escaping @MainActor () -> Void
  ) {
    self.read = read
    self.write = write
    self.onChange = onChange
  }

  public func refresh() async {
    guard !state.isChanging else { return }
    generation &+= 1
    let requestGeneration = generation
    do {
      let settings = try await read()
      guard requestGeneration == generation, !state.isChanging else { return }
      state.enabled = settings.enabled
      state.errorMessage = nil
    } catch {
      guard requestGeneration == generation else { return }
      state.errorMessage = BridgeServiceErrorMessage.message(error)
    }
  }

  public func setEnabled(_ enabled: Bool) async {
    guard state.enabled != nil, state.enabled != enabled, !state.isChanging else { return }
    generation &+= 1
    let requestGeneration = generation
    state.isChanging = true
    state.errorMessage = nil
    defer { if requestGeneration == generation { state.isChanging = false } }
    do {
      let settings = try await write(enabled)
      guard requestGeneration == generation else { return }
      state.enabled = settings.enabled
    } catch {
      guard requestGeneration == generation else { return }
      state.errorMessage = BridgeServiceErrorMessage.message(error)
    }
  }

  public func invalidate() {
    generation &+= 1
    state = WorkbenchSettingsStatus()
  }
}
