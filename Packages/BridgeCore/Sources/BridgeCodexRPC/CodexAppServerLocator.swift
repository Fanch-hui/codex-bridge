import Foundation

/// Holds the Codex app-server launch configuration.
///
/// Automatic discovery is evaluated on every spawn, so a Codex installed while
/// the service is running becomes usable without a restart. A user-configured
/// path stays strict and takes precedence until it is cleared.
public final class CodexAppServerLocator: @unchecked Sendable {
  private let lock = NSLock()
  private let automaticConfiguration: @Sendable () -> AppServerConfiguration
  private var configuredPath: String?

  /// Automatic discovery, re-evaluated on every spawn.
  public init() {
    automaticConfiguration = { AppServerConfiguration.codex() }
  }

  /// Pins automatic discovery to a fixed configuration.
  public init(configuration: AppServerConfiguration) {
    automaticConfiguration = { configuration }
  }

  init(resolve: @escaping @Sendable () -> AppServerConfiguration) {
    automaticConfiguration = resolve
  }

  public func current() -> AppServerConfiguration {
    lock.lock()
    let configured = configuredPath
    lock.unlock()
    guard let configured else { return automaticConfiguration() }
    return .codex(configuredPath: configured)
  }

  /// Applies a user-configured executable path; an empty path restores automatic
  /// discovery.
  public func update(configuredPath path: String?) {
    let normalized = path?.trimmingCharacters(in: .whitespacesAndNewlines)
    lock.lock()
    configuredPath = (normalized?.isEmpty ?? true) ? nil : normalized
    lock.unlock()
  }
}
