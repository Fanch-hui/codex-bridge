import BridgeAgentCore
import BridgeCodexRPC
import BridgeIPC
import BridgeLegacyImport
import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

#if os(Windows)
  import ucrt
  import WinSDK
#endif

public enum ServiceProcessArgumentError: Error, Equatable, LocalizedError, Sendable {
  case unknownArgument(String)
  case missingValue(String)
  case invalidDataRoot
  case invalidArgumentCombination

  public var errorDescription: String? {
    switch self {
    case .unknownArgument:
      "Codex Bridge service received an unknown argument."
    case .missingValue:
      "Codex Bridge service is missing an argument value."
    case .invalidDataRoot:
      "Codex Bridge service received an invalid data root."
    case .invalidArgumentCombination:
      "Codex Bridge service received an invalid argument combination."
    }
  }
}

public struct ServiceProcessOptions: Equatable, Sendable {
  public let foreground: Bool
  public let dataRootURL: URL
  public let shutdown: Bool
  public let shutdownIfIdle: Bool

  public init(
    foreground: Bool, dataRootURL: URL, shutdown: Bool = false, shutdownIfIdle: Bool = false
  ) {
    self.foreground = foreground
    self.dataRootURL = dataRootURL
    self.shutdown = shutdown
    self.shutdownIfIdle = shutdownIfIdle
  }

  public static func parse(_ arguments: [String]) throws -> ServiceProcessOptions {
    var foreground = false
    var shutdown = false
    var shutdownIfIdle = false
    var dataRootSpecified = false
    var dataRoot = ServiceDataPaths.defaultRoot()
    var index = 0
    while index < arguments.count {
      switch arguments[index] {
      case "--foreground":
        foreground = true
        index += 1
      case "--shutdown":
        #if os(Windows) || os(Linux)
          shutdown = true
          index += 1
        #else
          throw ServiceProcessArgumentError.unknownArgument("--shutdown")
        #endif
      case "--shutdown-if-idle":
        #if os(Linux)
          shutdownIfIdle = true
          index += 1
        #else
          throw ServiceProcessArgumentError.unknownArgument("--shutdown-if-idle")
        #endif
      case "--data-root":
        let valueIndex = index + 1
        guard valueIndex < arguments.count else {
          throw ServiceProcessArgumentError.missingValue("--data-root")
        }
        let value = arguments[valueIndex]
        guard !value.isEmpty,
          value.utf8.count <= 16_384,
          !value.contains("\0"),
          value.rangeOfCharacter(from: .controlCharacters) == nil,
          AgentPathSemantics.isAbsolute(value)
        else {
          throw ServiceProcessArgumentError.invalidDataRoot
        }
        dataRootSpecified = true
        dataRoot = URL(fileURLWithPath: value, isDirectory: true).standardizedFileURL
        index += 2
      default:
        throw ServiceProcessArgumentError.unknownArgument(arguments[index])
      }
    }
    guard !(shutdown && shutdownIfIdle),
      !(shutdown || shutdownIfIdle) || (!foreground && !dataRootSpecified)
    else {
      throw ServiceProcessArgumentError.invalidArgumentCombination
    }
    return ServiceProcessOptions(
      foreground: foreground,
      dataRootURL: dataRoot,
      shutdown: shutdown,
      shutdownIfIdle: shutdownIfIdle
    )
  }

}

public enum ServiceProcessRunner {
  public static func run(
    arguments: [String] = Array(CommandLine.arguments.dropFirst()),
    appVersion: String = "1.4.1"
  ) async throws {
    applyDefaultUmask()
    #if os(Windows)
      // The service runs detached in the user session; suppress hard-error
      // and crash-reporter popups for this process and every agent child
      // process it spawns (the error mode is inherited).
      _ = SetErrorMode(
        UINT(SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX | SEM_NOOPENFILEERRORBOX))
    #endif
    let options = try ServiceProcessOptions.parse(arguments)
    #if os(Linux)
      if options.shutdown || options.shutdownIfIdle {
        try await LinuxServiceShutdown.requestAndWait(requireIdle: options.shutdownIfIdle)
        return
      }
      try LinuxPackageMaintenance.requireAvailable()
    #endif
    #if os(Windows)
      if options.shutdown {
        try await WindowsServiceShutdown.requestAndWait()
        return
      }
      let instanceLock: WindowsServiceInstanceLock?
      if options.foreground {
        instanceLock = nil
      } else {
        instanceLock = try WindowsServiceInstanceLock()
      }
      defer { withExtendedLifetime(instanceLock) {} }
    #endif
    let dataLock = try ServiceDataRootLock(rootURL: options.dataRootURL)
    defer { withExtendedLifetime(dataLock) {} }
    let composition = try await ServiceComposition.make(
      configuration: ServiceCompositionConfiguration(
        appVersion: appVersion,
        dataRootURL: options.dataRootURL,
        clientInfo: .bridge(version: appVersion),
        legacyDataRootURL: LegacyConfigurationImporter.defaultSourceRoot()
      )
    )
    let logMaintenance = await ServiceLogMaintenance.start(store: composition.store)
    defer { logMaintenance.cancel() }
    let listener: (any ServiceRequestListener)?
    if options.foreground {
      listener = nil
    } else {
      #if os(Windows) || os(Linux)
        let active = try ServiceListenerFactory.makeListenerOrThrow(composition: composition)
      #else
        let active = ServiceListenerFactory.makeListener(composition: composition)
      #endif
      active.resume()
      listener = active
    }

    await composition.startAgentInstallationRefresh()

    do {
      let endpoint = try await composition.startLocalMCP()
      if options.foreground {
        FileHandle.standardOutput.write(
          Data("Codex Bridge service ready on 127.0.0.1:\(endpoint.port).\n".utf8)
        )
      }
    } catch {
      guard !options.foreground else { throw error }
      FileHandle.standardError.write(
        Data("Codex Bridge local MCP is unavailable; service control remains available.\n".utf8)
      )
    }

    await ServiceTerminationSignal.wait()
    listener?.invalidate()
    await composition.shutdown()
  }

  private static func applyDefaultUmask() {
    #if canImport(Darwin)
      _ = umask(0o077)
    #elseif canImport(Glibc)
      _ = umask(0o077)
    #elseif os(Windows)
      _ = _umask(0o077)
    #endif
  }

}

#if os(Windows)
  enum ServiceTerminationSignal {
    /// Bridges console lifecycle events (Ctrl+C, window close, logoff) into a
    /// one-shot continuation so the service can shut down cleanly.
    static func wait() async {
      await withCheckedContinuation { continuation in
        TerminationState.shared.start(continuation: continuation)
      }
    }

    static func request() {
      TerminationState.shared.finish()
    }
  }

  private final class TerminationState: @unchecked Sendable {
    static let shared = TerminationState()

    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var finished = false

    func start(continuation: CheckedContinuation<Void, Never>) {
      lock.lock()
      if finished {
        lock.unlock()
        continuation.resume()
        return
      }
      self.continuation = continuation
      lock.unlock()
      // A C function pointer cannot capture context, so the handler reports
      // to the process-wide shared state.
      _ = SetConsoleCtrlHandler(
        { _ in
          TerminationState.shared.finish()
          return true
        }, true)
    }

    func finish() {
      lock.lock()
      guard !finished else {
        lock.unlock()
        return
      }
      finished = true
      let continuation = continuation
      self.continuation = nil
      lock.unlock()
      continuation?.resume()
    }
  }
#endif
