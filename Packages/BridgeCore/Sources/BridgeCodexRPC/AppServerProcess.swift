@preconcurrency import Foundation

public struct AppServerConfiguration: Equatable, Sendable {
  public let executableURL: URL
  public let arguments: [String]
  public let currentDirectoryURL: URL?
  public let environment: [String: String]?
  public let maximumProtocolLineBytes: Int
  public let stderrBufferBytes: Int

  /// A non-nil reason marks a configuration that is known to be unusable: the
  /// app-server is not spawned and the reason is reported to the local user, so
  /// an unusable configured executable never degrades into a generic failure.
  public let launchFailureReason: String?

  public init(
    executableURL: URL,
    arguments: [String],
    currentDirectoryURL: URL? = nil,
    environment: [String: String]? = nil,
    maximumProtocolLineBytes: Int = 64 * 1024 * 1024,
    stderrBufferBytes: Int = 64 * 1024
  ) {
    self.init(
      executableURL: executableURL,
      arguments: arguments,
      currentDirectoryURL: currentDirectoryURL,
      environment: environment,
      maximumProtocolLineBytes: maximumProtocolLineBytes,
      stderrBufferBytes: stderrBufferBytes,
      launchFailureReason: nil
    )
  }

  init(
    executableURL: URL,
    arguments: [String],
    currentDirectoryURL: URL?,
    environment: [String: String]?,
    maximumProtocolLineBytes: Int,
    stderrBufferBytes: Int,
    launchFailureReason: String?
  ) {
    self.executableURL = executableURL
    self.arguments = arguments
    self.currentDirectoryURL = currentDirectoryURL
    self.environment = environment
    self.maximumProtocolLineBytes = max(1, maximumProtocolLineBytes)
    self.stderrBufferBytes = max(0, stderrBufferBytes)
    self.launchFailureReason = launchFailureReason
  }
}
