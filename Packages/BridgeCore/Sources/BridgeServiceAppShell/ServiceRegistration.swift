import BridgeServiceAppCore
import Darwin
import Foundation
import ServiceManagement

public enum BridgeServiceRegistrationError: Error, LocalizedError, Sendable {
  case executableNotFound
  case bootstrapFailed(Int32)
  case temporaryStopFailed
  case temporaryRestoreFailed

  public var errorDescription: String? {
    switch self {
    case .executableNotFound:
      "App Bundle 中没有找到 Codex Bridge 后台 Service 可执行文件。"
    case .bootstrapFailed(let code):
      "launchctl 未能载入后台服务（退出码 \(code)）。"
    case .temporaryStopFailed:
      "无法临时停止后台服务，请检查服务状态后重试。"
    case .temporaryRestoreFailed:
      "无法恢复之前临时停止的后台服务，请检查服务状态后重试。"
    }
  }
}

@MainActor
public protocol BridgeServiceRegistrationManaging: AnyObject {
  var status: BridgeServiceRegistrationStatus { get }
  /// The same answer as `status`, resolved without blocking the main thread.
  func probeStatus() async -> BridgeServiceRegistrationStatus
  var supportsAutomaticRecovery: Bool { get }

  func register() throws
  func unregister() async throws
  func stopTemporarily() async throws
  func resumeTemporaryStopIfNeeded() async throws
  func processIDsForShutdown() async throws -> [Int32]
  func waitForShutdown(processIDs: [Int32]) async throws
  func openSystemSettings()
  func recoverUnavailableService() async throws -> Bool
}

extension BridgeServiceRegistrationManaging {
  public func probeStatus() async -> BridgeServiceRegistrationStatus { status }
  public var supportsAutomaticRecovery: Bool { false }
  public func recoverUnavailableService() async throws -> Bool { false }
  public func stopTemporarily() async throws {
    throw BridgeServiceRegistrationError.temporaryStopFailed
  }
  public func resumeTemporaryStopIfNeeded() async throws {}
  public func processIDsForShutdown() async throws -> [Int32] { [] }
  public func waitForShutdown(processIDs: [Int32]) async throws {}
}

@MainActor
public final class SystemBridgeServiceRegistration: BridgeServiceRegistrationManaging {
  public var supportsAutomaticRecovery: Bool { true }

  private let service: SMAppService
  private let temporaryStopKey = "bridge.service.temporarilyStopped"
  private let plistName: String
  private let machServiceName: String

  public init(
    plistName: String = "org.codexbridge.service.plist",
    machServiceName: String = "org.codexbridge.service"
  ) {
    precondition(!plistName.isEmpty)
    precondition(!machServiceName.isEmpty)
    self.plistName = plistName
    self.machServiceName = machServiceName
    service = SMAppService.agent(plistName: plistName)
  }

  public var status: BridgeServiceRegistrationStatus {
    resolvedStatus(
      userLaunchAgentActive: Self.isUserLaunchAgentActive(
        plistPath: userLaunchAgentPlistURL.path, label: machServiceName))
  }

  public func probeStatus() async -> BridgeServiceRegistrationStatus {
    let plistPath = userLaunchAgentPlistURL.path
    let label = machServiceName
    let active = await Task.detached {
      SystemBridgeServiceRegistration.isUserLaunchAgentActive(plistPath: plistPath, label: label)
    }.value
    return resolvedStatus(userLaunchAgentActive: active)
  }

  private func resolvedStatus(userLaunchAgentActive: Bool) -> BridgeServiceRegistrationStatus {
    switch service.status {
    case .enabled:
      return .enabled
    case .requiresApproval:
      return .requiresApproval
    case .notRegistered, .notFound:
      break
    @unknown default:
      break
    }

    if userLaunchAgentRequiresApproval { return .requiresApproval }
    if userLaunchAgentActive { return .enabled }
    if locateServiceExecutable() != nil {
      return .notRegistered
    }

    return .notFound
  }

  public func register() throws {
    guard service.status != .requiresApproval, !userLaunchAgentRequiresApproval else { return }
    do {
      try service.register()
      if service.status == .enabled || service.status == .requiresApproval {
        return
      }
    } catch {
      let registrationError = error as NSError
      if service.status == .requiresApproval
        || (registrationError.domain == "SMAppServiceErrorDomain"
          && registrationError.code == kSMErrorLaunchDeniedByUser)
      {
        throw error
      }
    }

    guard let executable = locateServiceExecutable() else {
      throw BridgeServiceRegistrationError.executableNotFound
    }

    try registerUserLaunchAgent(executableURL: executable)
  }

  public func unregister() async throws {
    try? await service.unregister()
    unregisterUserLaunchAgent()
  }

  public func stopTemporarily() async throws {
    let processIDs = try await processIDsForShutdown()
    let legacy =
      FileManager.default.fileExists(atPath: userLaunchAgentPlistURL.path)
      && service.status != .enabled
    UserDefaults.standard.set(legacy ? "legacy" : "managed", forKey: temporaryStopKey)
    let label = machServiceName
    let active = await Task.detached {
      Self.isLaunchAgentActive(label: label)
    }.value
    if active {
      let stopped = await Task.detached {
        Self.runLaunchctl(["bootout", "gui/\(getuid())/\(label)"])
      }.value
      guard stopped else {
        UserDefaults.standard.removeObject(forKey: temporaryStopKey)
        throw BridgeServiceRegistrationError.temporaryStopFailed
      }
    }
    try await waitForShutdown(processIDs: processIDs)
  }

  public func resumeTemporaryStopIfNeeded() async throws {
    guard let original = UserDefaults.standard.string(forKey: temporaryStopKey) else { return }
    let label = machServiceName
    let active = await Task.detached { Self.isLaunchAgentActive(label: label) }.value
    if active {
      UserDefaults.standard.removeObject(forKey: temporaryStopKey)
      return
    }
    let plist: URL
    if original == "legacy" {
      guard FileManager.default.fileExists(atPath: userLaunchAgentPlistURL.path) else {
        UserDefaults.standard.removeObject(forKey: temporaryStopKey)
        return
      }
      plist = userLaunchAgentPlistURL
    } else {
      guard service.status == .enabled else {
        UserDefaults.standard.removeObject(forKey: temporaryStopKey)
        return
      }
      guard let executable = locateServiceExecutable() else {
        throw BridgeServiceRegistrationError.executableNotFound
      }
      plist = try makeTemporaryBootstrapPlist(executable: executable)
    }
    defer { if original != "legacy" { try? FileManager.default.removeItem(at: plist) } }
    let success = await Task.detached {
      Self.runLaunchctl(["bootstrap", "gui/\(getuid())", plist.path])
    }.value
    guard success else { throw BridgeServiceRegistrationError.temporaryRestoreFailed }
    UserDefaults.standard.removeObject(forKey: temporaryStopKey)
  }

  public func processIDsForShutdown() async throws -> [Int32] {
    guard
      let executable = locateServiceExecutable()
        ?? Bundle.main.resourceURL?
        .appendingPathComponent("CodexBridgeService")
    else { throw BridgeServiceRegistrationError.executableNotFound }
    return try await MacAppUpdateServiceExit.processIDs(serviceExecutableURL: executable)
  }

  public func waitForShutdown(processIDs: [Int32]) async throws {
    try await MacAppUpdateServiceExit.wait(for: processIDs)
  }

  public func openSystemSettings() {
    SMAppService.openSystemSettingsLoginItems()
  }

  public func recoverUnavailableService() async throws -> Bool {
    guard await probeStatus() == .enabled else { return false }
    let label = machServiceName
    let managed = service.status == .enabled
    let needsAbsolutePath =
      managed
      ? await Task.detached { Self.hasBundleProgramLaunchFailure(label: label) }.value
      : false
    guard !managed || service.status == .enabled, !userLaunchAgentRequiresApproval else {
      return false
    }
    if needsAbsolutePath {
      guard let executable = locateServiceExecutable() else {
        throw BridgeServiceRegistrationError.executableNotFound
      }
      // Re-registering the same BundleProgram repeats launchd's pre-exec failure.
      try await service.unregister()
      try registerUserLaunchAgent(executableURL: executable)
    } else {
      try await unregister()
      try register()
    }
    return await probeStatus() == .enabled
  }

  private var userLaunchAgentPlistURL: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
      .appendingPathComponent(plistName, isDirectory: false)
  }

  private func locateServiceExecutable() -> URL? {
    if let bundled = Bundle.main.url(forResource: "CodexBridgeService", withExtension: nil),
      FileManager.default.isExecutableFile(atPath: bundled.path)
    {
      return bundled
    }
    if let resourceURL = Bundle.main.resourceURL {
      let candidate = resourceURL.appendingPathComponent("CodexBridgeService")
      if FileManager.default.isExecutableFile(atPath: candidate.path) {
        return candidate
      }
    }
    if let executable = Bundle.main.executableURL {
      let bundleRoot = executable.deletingLastPathComponent().deletingLastPathComponent()
      let candidate = bundleRoot.appendingPathComponent("Resources/CodexBridgeService")
      if FileManager.default.isExecutableFile(atPath: candidate.path) {
        return candidate
      }
    }
    return nil
  }

  private func makeTemporaryBootstrapPlist(executable: URL) throws -> URL {
    let value: [String: Any] = [
      "Label": machServiceName,
      "ProgramArguments": [executable.path],
      "MachServices": [machServiceName: true],
      "RunAtLoad": true,
      "KeepAlive": ["SuccessfulExit": false],
      "ProcessType": "Interactive",
    ]
    let data = try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(
      "codex-bridge-bootstrap-\(UUID().uuidString).plist")
    try data.write(to: path, options: .atomic)
    return path
  }

  private nonisolated static func runLaunchctl(_ arguments: [String]) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
      try process.run()
      process.waitUntilExit()
      return process.terminationStatus == 0
    } catch {
      return false
    }
  }

  private nonisolated static func isLaunchAgentActive(label: String) -> Bool {
    runLaunchctl(["print", "gui/\(getuid())/\(label)"])
  }

  private nonisolated static func isUserLaunchAgentActive(
    plistPath: String, label: String
  ) -> Bool {
    FileManager.default.fileExists(atPath: plistPath) && isLaunchAgentActive(label: label)
  }

  private var userLaunchAgentRequiresApproval: Bool {
    FileManager.default.fileExists(atPath: userLaunchAgentPlistURL.path)
      && SMAppService.statusForLegacyPlist(at: userLaunchAgentPlistURL) == .requiresApproval
  }

  private nonisolated static func hasBundleProgramLaunchFailure(label: String) -> Bool {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    process.arguments = ["print", "gui/\(getuid())/\(label)"]
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    do {
      try process.run()
    } catch {
      return false
    }
    let report = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return process.terminationStatus == 0
      && isBundleProgramLaunchFailure(String(decoding: report, as: UTF8.self))
  }

  nonisolated static func isBundleProgramLaunchFailure(_ report: String) -> Bool {
    let fields = report.split(whereSeparator: \.isNewline).map {
      $0.trimmingCharacters(in: .whitespaces)
    }
    let program = "program identifier = Contents/Resources/CodexBridgeService"
    return fields.contains("job state = spawn failed")
      && fields.contains { $0 == "last exit code = 78" || $0 == "last exit code = 78: EX_CONFIG" }
      && fields.contains { $0 == program || $0.hasPrefix(program + " (") }
  }

  private func registerUserLaunchAgent(executableURL: URL) throws {
    let launchAgentsDir = userLaunchAgentPlistURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: launchAgentsDir, withIntermediateDirectories: true)

    let plistDict: [String: Any] = [
      "Label": machServiceName,
      "ProgramArguments": [executableURL.path],
      "MachServices": [
        machServiceName: true
      ],
      "RunAtLoad": true,
      "KeepAlive": true,
      "ProcessType": "Interactive",
    ]
    let data = try PropertyListSerialization.data(
      fromPropertyList: plistDict,
      format: .xml,
      options: 0
    )
    try data.write(to: userLaunchAgentPlistURL, options: .atomic)

    let uid = getuid()
    let bootstrap = Process()
    bootstrap.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    bootstrap.arguments = ["bootstrap", "gui/\(uid)", userLaunchAgentPlistURL.path]
    bootstrap.standardOutput = FileHandle.nullDevice
    bootstrap.standardError = FileHandle.nullDevice
    try bootstrap.run()
    bootstrap.waitUntilExit()
    guard bootstrap.terminationStatus == 0 else {
      throw BridgeServiceRegistrationError.bootstrapFailed(bootstrap.terminationStatus)
    }
  }

  private func unregisterUserLaunchAgent() {
    let uid = getuid()
    let bootout = Process()
    bootout.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    bootout.arguments = ["bootout", "gui/\(uid)/\(machServiceName)"]
    bootout.standardOutput = Pipe()
    bootout.standardError = Pipe()
    try? bootout.run()
    bootout.waitUntilExit()

    if bootout.terminationStatus != 0 {
      let unload = Process()
      unload.executableURL = URL(fileURLWithPath: "/bin/launchctl")
      unload.arguments = ["unload", userLaunchAgentPlistURL.path]
      unload.standardOutput = Pipe()
      unload.standardError = Pipe()
      try? unload.run()
      unload.waitUntilExit()
    }

    try? FileManager.default.removeItem(at: userLaunchAgentPlistURL)
  }
}
