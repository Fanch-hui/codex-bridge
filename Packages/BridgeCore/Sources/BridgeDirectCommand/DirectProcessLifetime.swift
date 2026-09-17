import BridgeAgentCore
import BridgeProcess
import Foundation

public struct DirectProcessIdentity: Codable, Equatable, Sendable {
  public let pid: Int32
  public let startTimeMicros: Int64
  public let processGroupID: Int32

  public init(pid: Int32, startTimeMicros: Int64, processGroupID: Int32) {
    self.pid = pid
    self.startTimeMicros = startTimeMicros
    self.processGroupID = processGroupID
  }
}

public enum DirectProcessTermination: Equatable, Sendable {
  case exited(Int32)
  case killed(Int32)
  case notStarted
}

public enum DirectProcessError: Error, Equatable, Sendable {
  case invalidArgument
  case processLaunchFailed(Int32)
  case stdinUnavailable
  case sandboxUnavailable
}

public final class DirectProcessLifetime: @unchecked Sendable {
  public let pid: Int32
  #if os(Windows)
    private enum Backend {
      case managed(ManagedStdioProcess)
      case container(WindowsAppContainerProcess)
    }
    private let backend: Backend
  #else
    private let process: ManagedStdioProcess
  #endif

  public var identity: DirectProcessIdentity? {
    #if os(Windows)
      switch backend {
      case .managed(let proc):
        return proc.identity.map(Self.directIdentity)
      case .container(let proc):
        return DirectProcessIdentity(
          pid: proc.pid,
          startTimeMicros: 0,
          processGroupID: proc.pid
        )
      }
    #else
      process.identity.map(Self.directIdentity)
    #endif
  }

  public init(
    argv: [String],
    workingDirectory: String?,
    environment: [String: String]?,
    usePTY: Bool,
    output: DirectCommandOutputCollector,
    denyNetwork: Bool = false
  ) throws {
    guard let executable = argv.first, !executable.isEmpty, argv.count <= 128, !usePTY else {
      throw DirectProcessError.invalidArgument
    }
    let environment = Self.defaultEnvironment(overrides: environment)
    #if os(Windows)
      if denyNetwork {
        do {
          let container = try WindowsAppContainerProcess(
            argv: argv,
            workingDirectory: workingDirectory,
            environment: environment,
            onOutput: { output.append($0) }
          )
          self.backend = .container(container)
          self.pid = container.pid
        } catch let error as DirectProcessError {
          throw error
        } catch {
          throw DirectProcessError.sandboxUnavailable
        }
      } else {
        do {
          let managed = try ManagedStdioProcess(
            argv: argv,
            workingDirectory: workingDirectory,
            environment: environment,
            mergeStandardError: true,
            onStandardOutput: { output.append($0) }
          )
          self.backend = .managed(managed)
          self.pid = managed.pid
        } catch let error as ManagedProcessError {
          throw Self.directError(error)
        }
      }
    #else
      let launchArgv: [String]
      if denyNetwork {
        guard Self.sandboxExecAvailable else { throw DirectProcessError.sandboxUnavailable }
        launchArgv = [Self.sandboxExecPath, "-p", Self.denyNetworkProfile, "--"] + argv
      } else {
        launchArgv = argv
      }
      do {
        process = try ManagedStdioProcess(
          argv: launchArgv,
          workingDirectory: workingDirectory,
          environment: environment,
          mergeStandardError: true,
          onStandardOutput: { output.append($0) }
        )
      } catch let error as ManagedProcessError {
        throw Self.directError(error)
      }
      pid = process.pid
    #endif
  }

  public func writeStdin(_ data: Data) throws {
    #if os(Windows)
      switch backend {
      case .managed(let proc):
        do {
          try proc.writeStdin(data)
        } catch {
          throw DirectProcessError.stdinUnavailable
        }
      case .container(let proc):
        try proc.writeStdin(data)
      }
    #else
      do {
        try process.writeStdin(data)
      } catch {
        throw DirectProcessError.stdinUnavailable
      }
    #endif
  }

  public func closeStdin() {
    #if os(Windows)
      switch backend {
      case .managed(let proc): proc.closeStdin()
      case .container(let proc): proc.closeStdin()
      }
    #else
      process.closeStdin()
    #endif
  }

  public func terminateGroup() {
    #if os(Windows)
      switch backend {
      case .managed(let proc): proc.terminateGroup()
      case .container(let proc): proc.terminateGroup()
      }
    #else
      process.terminateGroup()
    #endif
  }

  public func killGroup() {
    #if os(Windows)
      switch backend {
      case .managed(let proc): proc.killGroup()
      case .container(let proc): proc.killGroup()
      }
    #else
      process.killGroup()
    #endif
  }

  public var isRunning: Bool {
    #if os(Windows)
      switch backend {
      case .managed(let proc): return proc.isRunning
      case .container(let proc): return proc.isRunning
      }
    #else
      return process.isRunning
    #endif
  }

  public func reapIfExited(gracePeriod: Duration = .milliseconds(200))
    -> DirectProcessTermination?
  {
    #if os(Windows)
      switch backend {
      case .managed(let proc):
        return proc.reapIfExited(gracePeriod: gracePeriod).map(Self.directTermination)
      case .container(let proc):
        return proc.reapIfExited(gracePeriod: gracePeriod)
      }
    #else
      process.reapIfExited(gracePeriod: gracePeriod).map(Self.directTermination)
    #endif
  }

  public func waitForExit(timeout: Duration) -> DirectProcessTermination? {
    #if os(Windows)
      switch backend {
      case .managed(let proc):
        return proc.waitForExit(timeout: timeout).map(Self.directTermination)
      case .container(let proc):
        return proc.waitForExit(timeout: timeout)
      }
    #else
      process.waitForExit(timeout: timeout).map(Self.directTermination)
    #endif
  }

  public func terminateAndWait(
    gracePeriod: Duration = .seconds(1),
    killWait: Duration = .seconds(5)
  ) -> DirectProcessTermination? {
    #if os(Windows)
      switch backend {
      case .managed(let proc):
        return proc.terminateAndWait(gracePeriod: gracePeriod, killWait: killWait)
          .map(Self.directTermination)
      case .container(let proc):
        return proc.terminateAndWait(gracePeriod: gracePeriod, killWait: killWait)
      }
    #else
      process.terminateAndWait(gracePeriod: gracePeriod, killWait: killWait)
        .map(Self.directTermination)
    #endif
  }

  public func pollOutput() {}

  public func drainRemainingOutput() {
    #if os(Windows)
      switch backend {
      case .managed(let proc): proc.drainRemainingOutput()
      case .container(let proc): proc.drainRemainingOutput()
      }
    #else
      process.drainRemainingOutput()
    #endif
  }

  public func close() {
    #if os(Windows)
      switch backend {
      case .managed(let proc): proc.close()
      case .container(let proc): proc.close()
      }
    #else
      process.close()
    #endif
  }

  public static func identity(of processID: Int32) -> DirectProcessIdentity? {
    ManagedStdioProcess.identity(of: processID).map(directIdentity)
  }

  public static func matchesCurrentProcess(_ identity: DirectProcessIdentity) -> Bool {
    ManagedStdioProcess.matchesCurrentProcess(
      ManagedProcessIdentity(
        pid: identity.pid,
        startTimeMicros: identity.startTimeMicros,
        processGroupID: identity.processGroupID
      )
    )
  }

  private static func directIdentity(_ identity: ManagedProcessIdentity) -> DirectProcessIdentity {
    DirectProcessIdentity(
      pid: identity.pid,
      startTimeMicros: identity.startTimeMicros,
      processGroupID: identity.processGroupID
    )
  }

  private static func directTermination(
    _ termination: ManagedProcessTermination
  ) -> DirectProcessTermination {
    switch termination {
    case .exited(let code): .exited(code)
    case .killed(let signal): .killed(signal)
    case .notStarted: .notStarted
    }
  }

  private static func directError(_ error: ManagedProcessError) -> DirectProcessError {
    switch error {
    case .invalidArgument: .invalidArgument
    case .processLaunchFailed(let code): .processLaunchFailed(code)
    case .stdinUnavailable: .stdinUnavailable
    }
  }

  private static let sandboxExecPath = "/usr/bin/sandbox-exec"
  private static let sandboxExecAvailable = FileManager.default.isExecutableFile(
    atPath: sandboxExecPath
  )
  private static let denyNetworkProfile = "(version 1)(allow default)(deny network*)"

  public static func defaultEnvironment(overrides: [String: String]? = nil) -> [String: String] {
    #if os(Windows)
      return windowsEnvironment(overrides: overrides)
    #else
      var environment: [String: String] = [:]
      let processEnv = ProcessInfo.processInfo.environment
      for key in ["HOME", "USER", "LOGNAME", "TMPDIR", "SHELL", "LANG", "LC_ALL"] {
        if let value = processEnv[key] {
          environment[key] = value
        }
      }
      if environment["HOME"] == nil {
        environment["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path
      }
      if environment["TMPDIR"] == nil {
        environment["TMPDIR"] = NSTemporaryDirectory()
      }
      let trustedDirectories = [
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path,
        "/usr/local/bin",
        "/opt/homebrew/bin",
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin",
      ]
      if let currentPath = processEnv["PATH"], !currentPath.isEmpty {
        let existing = currentPath.split(separator: ":").map(String.init)
        var combined = existing
        for dir in trustedDirectories where !combined.contains(dir) {
          combined.append(dir)
        }
        environment["PATH"] = combined.joined(separator: ":")
      } else {
        environment["PATH"] = trustedDirectories.joined(separator: ":")
      }
      if let overrides {
        environment.merge(overrides) { _, replacement in replacement }
      }
      return environment
    #endif
  }

  #if os(Windows)
    private static func windowsEnvironment(overrides: [String: String]?) -> [String: String] {
      let current = ProcessInfo.processInfo.environment
      let preserved = [
        "SystemRoot", "WINDIR", "SystemDrive", "ComSpec", "TEMP", "TMP", "USERPROFILE",
        "HOMEDRIVE", "HOMEPATH", "HOME", "LOCALAPPDATA", "APPDATA", "ProgramFiles",
        "ProgramFiles(x86)", "ProgramW6432", "PATH", "PATHEXT", "LANG", "LC_ALL",
      ]
      var environment: [String: String] = [:]
      for key in preserved {
        if let value = environmentValue(key, in: current) {
          environment[key] = value
        }
      }
      let home =
        environment["USERPROFILE"] ?? environment["HOME"]
        ?? FileManager.default.homeDirectoryForCurrentUser.path
      environment["USERPROFILE"] = home
      environment["HOME"] = environment["HOME"] ?? home
      let temporary = environment["TEMP"] ?? environment["TMP"] ?? NSTemporaryDirectory()
      environment["TEMP"] = temporary
      environment["TMP"] = environment["TMP"] ?? temporary
      environment["PATHEXT"] = environment["PATHEXT"] ?? ".COM;.EXE;.BAT;.CMD"
      let resolver = AgentExecutableResolver(
        environment: current,
        includeEnvironmentPath: false,
        preferredExtensions: [".EXE"]
      )
      let trustedPath = resolver.searchDirectories()
      let inheritedPath = environment["PATH"].map { splitWindowsPath($0) } ?? []
      var path = inheritedPath
      for directory in trustedPath
      where !path.contains(where: {
        $0.caseInsensitiveCompare(directory) == .orderedSame
      }) {
        path.append(directory)
      }
      environment["PATH"] = path.joined(separator: ";")
      if let overrides {
        for (key, value) in overrides {
          if let existingKey = environment.keys.first(where: {
            $0.caseInsensitiveCompare(key) == .orderedSame
          }) {
            environment.removeValue(forKey: existingKey)
          }
          environment[key] = value
        }
      }
      return environment
    }

    private static func environmentValue(
      _ name: String,
      in environment: [String: String]
    ) -> String? {
      guard
        let key = environment.keys.first(where: {
          $0.caseInsensitiveCompare(name) == .orderedSame
        })
      else { return nil }
      let value = environment[key] ?? ""
      return value.isEmpty ? nil : value
    }

    private static func splitWindowsPath(_ value: String) -> [String] {
      var result: [String] = []
      var component = ""
      var quoted = false
      for character in value {
        if character == "\"" {
          quoted.toggle()
        } else if character == ";", !quoted {
          let trimmed = component.trimmingCharacters(in: .whitespacesAndNewlines)
          if !trimmed.isEmpty { result.append(trimmed) }
          component.removeAll(keepingCapacity: true)
        } else {
          component.append(character)
        }
      }
      if !quoted {
        let trimmed = component.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { result.append(trimmed) }
      }
      return result
    }
  #endif
}
