import BridgeAgentCore
import Foundation

public enum DirectGitError: Error, Equatable, Sendable {
  case invalidArgument
  case notGitRepository
  case launchFailed
  case timedOut
}

public enum DirectGitCommitError: Error, Equatable, Sendable {
  case gitFailed(String)
  case outputTruncated
  case malformedOutput
}

public struct DirectGitResult: Equatable, Sendable {
  public let exitCode: Int32
  public let output: DirectCommandOutputBuffer
  public let completeOutput: Data?

  public init(
    exitCode: Int32,
    output: DirectCommandOutputBuffer,
    completeOutput: Data? = nil
  ) {
    self.exitCode = exitCode
    self.output = output
    self.completeOutput = completeOutput
  }
}

/// Runs one bounded, non-interactive git command inside the project root and
/// captures bounded head/tail output. Used by the controlled Direct Git
/// commit path so that no shell is involved and no history rewrite is possible.
public struct DirectGitRunner: Sendable {
  public static var gitPath: String {
    #if os(Windows)
      return (try? resolveGitPath()) ?? "git.exe"
    #else
      return "/usr/bin/git"
    #endif
  }

  public static func resolveGitPath(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) throws -> String {
    #if os(Windows)
      guard
        let path = AgentExecutableResolver(
          environment: environment,
          includeEnvironmentPath: true,
          preferredExtensions: [".EXE"]
        ).resolve("git")
      else {
        throw DirectGitError.launchFailed
      }
      return path
    #else
      return "/usr/bin/git"
    #endif
  }

  public let defaultTimeout: Duration

  public init(defaultTimeout: Duration = .seconds(60)) {
    self.defaultTimeout = defaultTimeout
  }

  public func run(
    argv: [String],
    workingDirectory: String,
    timeout: Duration? = nil,
    environment overrides: [String: String]? = nil,
    maximumOutputBytes: Int = 256 * 1_024,
    restrictedEnvironment: Bool = false
  ) async throws -> DirectGitResult {
    guard let executable = argv.first, !executable.isEmpty, argv.count <= 128,
      maximumOutputBytes > 0, maximumOutputBytes <= 20 * 1_024 * 1_024
    else {
      throw DirectGitError.invalidArgument
    }
    let launchArgv = try Self.resolvedArgv(argv)
    let operation = Task.detached(priority: .userInitiated) {
      try await execute(
        argv: launchArgv, workingDirectory: workingDirectory,
        timeout: timeout ?? defaultTimeout, overrides: overrides,
        maximumOutputBytes: maximumOutputBytes, restrictedEnvironment: restrictedEnvironment
      )
    }
    return try await withTaskCancellationHandler {
      try await operation.value
    } onCancel: {
      operation.cancel()
    }
  }

  private func execute(
    argv: [String], workingDirectory: String, timeout: Duration,
    overrides: [String: String]?, maximumOutputBytes: Int, restrictedEnvironment: Bool
  ) async throws -> DirectGitResult {
    try Task.checkCancellation()
    // Inspection relies on the process whitelist and excludes Git repository/config redirection.
    var environment = restrictedEnvironment ? [:] : Self.environmentOverrides()
    if let overrides {
      let permitted =
        restrictedEnvironment
        ? overrides.filter { !$0.key.uppercased().hasPrefix("GIT_") } : overrides
      environment.merge(permitted) { _, replacement in replacement }
    }
    let collector = DirectCommandOutputCollector(maximumBytes: maximumOutputBytes)
    let process: DirectProcessLifetime
    do {
      process = try DirectProcessLifetime(
        argv: argv, workingDirectory: workingDirectory, environment: environment,
        usePTY: false, output: collector
      )
    } catch {
      throw DirectGitError.launchFailed
    }
    defer {
      if process.isRunning { _ = process.terminateAndWait(gracePeriod: .seconds(1)) }
      process.close()
    }
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while process.isRunning && ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    try Task.checkCancellation()
    guard !process.isRunning,
      let termination = process.waitForExit(timeout: .seconds(1))
    else { throw DirectGitError.timedOut }
    process.drainRemainingOutput()
    let exitCode: Int32
    if case .exited(let code) = termination { exitCode = code } else { exitCode = -1 }
    return DirectGitResult(
      exitCode: exitCode, output: collector.snapshot(), completeOutput: collector.completeData()
    )
  }

  private static func resolvedArgv(_ argv: [String]) throws -> [String] {
    #if os(Windows)
      guard let executable = argv.first else { throw DirectGitError.invalidArgument }
      let isBareGit =
        !AgentPathSemantics.isAbsolute(executable, style: .windows)
        && !executable.contains("/") && !executable.contains("\\")
        && ["git", "git.exe"].contains(executable.lowercased())
      guard isBareGit else { return argv }
      return [try resolveGitPath()] + argv.dropFirst()
    #else
      return argv
    #endif
  }

  private static func environmentOverrides() -> [String: String] {
    #if os(Windows)
      return [:]
    #else
      var environment = ProcessInfo.processInfo.environment
      environment["PATH"] = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
      return environment
    #endif
  }
}
