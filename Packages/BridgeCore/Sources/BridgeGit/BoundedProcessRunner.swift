import Foundation

public enum BoundedProcessTermination: Equatable, Sendable {
  case exited(Int32)
  case outputLimit
}

public struct BoundedProcessResult: Equatable, Sendable {
  public let termination: BoundedProcessTermination
  public let standardOutput: Data
  public let standardError: Data
  public let standardOutputTruncated: Bool
  public let standardErrorTruncated: Bool
}

public struct BoundedProcessConfiguration: Sendable {
  public let executableURL: URL
  public let arguments: [String]
  public let workingDirectory: OpenedWorkingDirectory
  public let environment: [String]
  public let timeout: Duration
  public let terminationGracePeriod: Duration
  public let maximumStandardOutputBytes: Int
  public let maximumStandardErrorBytes: Int

  public init(
    executableURL: URL,
    arguments: [String],
    workingDirectory: OpenedWorkingDirectory,
    environment: [String],
    timeout: Duration,
    terminationGracePeriod: Duration,
    maximumStandardOutputBytes: Int,
    maximumStandardErrorBytes: Int
  ) {
    self.executableURL = executableURL
    self.arguments = arguments
    self.workingDirectory = workingDirectory
    self.environment = environment
    self.timeout = timeout
    self.terminationGracePeriod = terminationGracePeriod
    self.maximumStandardOutputBytes = maximumStandardOutputBytes
    self.maximumStandardErrorBytes = maximumStandardErrorBytes
  }
}

public enum BoundedProcessError: Error, Equatable, Sendable {
  case invalidConfiguration
  case launchFailed
  case timedOut
  case waitFailed
}

public struct BoundedProcessRunner: Sendable {
  public init() {}

  public func run(
    _ configuration: BoundedProcessConfiguration
  ) async throws -> BoundedProcessResult {
    try BoundedProcessLauncher.validate(configuration)
    var child = try BoundedProcessPlatformLauncher.spawn(configuration)
    do {
      return try await monitor(&child, configuration: configuration)
    } catch {
      _ = await terminateAndReap(
        &child,
        gracePeriod: configuration.terminationGracePeriod
      )
      child.drainAfterExit()
      throw error
    }
  }

  private func monitor(
    _ child: inout BoundedProcessChild,
    configuration: BoundedProcessConfiguration
  ) async throws -> BoundedProcessResult {
    let clock = ContinuousClock()
    let timeout = min(max(configuration.timeout, .milliseconds(1)), .seconds(120))
    let deadline = clock.now.advanced(by: timeout)

    while true {
      child.drainOutput()
      if child.outputExceededLimit {
        _ = await terminateAndReap(
          &child,
          gracePeriod: configuration.terminationGracePeriod
        )
        child.drainAfterExit()
        return child.result(termination: .outputLimit)
      }
      if let code = try child.pollExit() {
        child.drainAfterExit()
        return child.result(termination: .exited(code))
      }
      if Task.isCancelled { throw CancellationError() }
      if clock.now >= deadline { throw BoundedProcessError.timedOut }
      try await Task.sleep(for: .milliseconds(5))
    }
  }

  private func terminateAndReap(
    _ child: inout BoundedProcessChild,
    gracePeriod: Duration
  ) async -> Int32? {
    child.requestTermination()
    let clock = ContinuousClock()
    let grace = min(max(gracePeriod, .zero), .seconds(2))
    let deadline = clock.now.advanced(by: grace)
    while clock.now < deadline {
      child.drainOutput()
      if let code = try? child.pollExit() { return code }
      try? await Task.sleep(for: .milliseconds(10))
    }

    child.forceTermination()
    let killDeadline = clock.now.advanced(by: .seconds(2))
    while clock.now < killDeadline {
      child.drainOutput()
      if let code = try? child.pollExit() { return code }
      try? await Task.sleep(for: .milliseconds(5))
    }
    return nil
  }
}
