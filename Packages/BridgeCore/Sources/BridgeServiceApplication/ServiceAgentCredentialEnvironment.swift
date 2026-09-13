import BridgeAgentCore
import BridgeSecurity
import Crypto
import Foundation

public enum ServiceAgentCredentialError: Error, Equatable, LocalizedError, Sendable {
  case unsupportedProvider(AgentProviderID)
  case invalidBaseURL
  case invalidAPIKey
  case invalidConfigurationPath
  case invalidStoredAPIKey

  public var errorDescription: String? {
    switch self {
    case .unsupportedProvider:
      "The Agent Provider does not accept connection credentials."
    case .invalidBaseURL:
      "The Agent Base URL is invalid."
    case .invalidAPIKey:
      "The Agent API key is invalid."
    case .invalidConfigurationPath:
      "The Agent configuration path is invalid."
    case .invalidStoredAPIKey:
      "The stored Agent API key is invalid."
    }
  }
}

/// Resolves provider credentials at process-launch time. Secrets stay in the
/// platform secret store and are copied only into the child process environment.
public actor ServiceAgentCredentialEnvironment {
  private let secretStore: any SecretStore
  private let sourceEnvironment: [String: String]
  private var deepSeekBaseURLs: [String: String]
  private var managedDeepSeekConfigurationPaths: Set<String>

  public init(
    secretStore: any SecretStore,
    sourceEnvironment: [String: String] = ProcessInfo.processInfo.environment,
    deepSeekBaseURL: String? = nil,
    managedDeepSeekConfigurationPath: String? = nil
  ) {
    self.secretStore = secretStore
    self.sourceEnvironment = sourceEnvironment
    if let deepSeekBaseURL = deepSeekBaseURL.flatMap({ try? Self.validatedBaseURL($0) }),
      let path = Self.canonicalConfigurationPath(managedDeepSeekConfigurationPath)
    {
      self.deepSeekBaseURLs = [path: deepSeekBaseURL]
      self.managedDeepSeekConfigurationPaths = [path]
    } else {
      self.deepSeekBaseURLs = [:]
      self.managedDeepSeekConfigurationPaths = []
    }
  }

  public func configureDeepSeekHarness(
    baseURL: String?,
    apiKey: String?,
    configurationPath: String
  ) throws {
    let normalizedBaseURL = try baseURL.map(Self.validatedBaseURL)
    let normalizedAPIKey = try apiKey.map(Self.validatedAPIKey)
    guard let canonicalPath = Self.canonicalConfigurationPath(configurationPath) else {
      throw ServiceAgentCredentialError.invalidConfigurationPath
    }
    let reference = try Self.deepSeekHarnessAPIKeyReference(for: canonicalPath)
    if let normalizedAPIKey {
      try secretStore.store(Data(normalizedAPIKey.utf8), for: reference)
    }
    if let normalizedBaseURL {
      deepSeekBaseURLs[canonicalPath] = normalizedBaseURL
    }
    managedDeepSeekConfigurationPaths.insert(canonicalPath)
  }

  public func configuredDeepSeekBaseURL(for configurationPath: String) -> String? {
    guard let path = Self.canonicalConfigurationPath(configurationPath) else { return nil }
    return deepSeekBaseURLs[path]
  }

  public func runtimeEnvironment(
    for installation: AgentInstallation
  ) throws -> [String: String] {
    guard installation.providerID == .deepSeekHarness else {
      throw ServiceAgentCredentialError.unsupportedProvider(installation.providerID)
    }
    var environment = sourceEnvironment
    removeCredentialEntries(from: &environment)
    guard
      let configurationPath = installation.artifacts.first(where: {
        $0.role == .launchConfiguration
      })?.canonicalPath,
      let canonicalPath = Self.canonicalConfigurationPath(configurationPath),
      managedDeepSeekConfigurationPaths.contains(canonicalPath)
    else {
      return environment
    }
    if let baseURL = deepSeekBaseURLs[canonicalPath] {
      environment["DEEPSEEK_BASE_URL"] = baseURL
    }
    let reference = try Self.deepSeekHarnessAPIKeyReference(for: canonicalPath)
    do {
      let data = try secretStore.load(reference)
      guard let apiKey = String(data: data, encoding: .utf8) else {
        throw ServiceAgentCredentialError.invalidStoredAPIKey
      }
      environment["DEEPSEEK_API_KEY"] = try Self.validatedAPIKey(apiKey)
    } catch SecretStoreError.notFound {
      // An existing external DSH profile may still provide its own .env.
    }
    return environment
  }

  private func removeCredentialEntries(from environment: inout [String: String]) {
    let credentialKeys = Set(["DEEPSEEK_API_KEY", "DEEPSEEK_BASE_URL", "DEEPSEEK_SEARCH_BASE_URL"])
    for key in Array(environment.keys) where credentialKeys.contains(key.uppercased()) {
      environment.removeValue(forKey: key)
    }
  }

  private static func canonicalConfigurationPath(_ value: String?) -> String? {
    guard let value,
      AgentPathSemantics.isAbsolute(value),
      !value.contains("\0"),
      value.rangeOfCharacter(from: .controlCharacters) == nil,
      let canonical = AgentPathSemantics.canonicalPath(value)
    else { return nil }
    return canonical
  }

  private static func deepSeekHarnessAPIKeyReference(
    for configurationPath: String
  ) throws -> SecretReference {
    let digest = SHA256.hash(data: Data(configurationPath.utf8))
      .map { String(format: "%02x", $0) }
      .joined()
    return try SecretReference(validating: "agent.deepseek-harness.api-key.\(digest)")
  }

  private static func validatedBaseURL(_ value: String) throws -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty,
      trimmed.utf8.count <= 4_096,
      !trimmed.contains("\0"),
      trimmed.rangeOfCharacter(from: .controlCharacters) == nil,
      let url = URL(string: trimmed),
      let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
      url.host != nil,
      url.user == nil,
      url.password == nil,
      url.query == nil,
      url.fragment == nil
    else {
      throw ServiceAgentCredentialError.invalidBaseURL
    }
    return trimmed
  }

  private static func validatedAPIKey(_ value: String) throws -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty,
      trimmed.utf8.count <= 16 * 1_024,
      !trimmed.contains("\0"),
      trimmed.rangeOfCharacter(from: .controlCharacters) == nil
    else {
      throw ServiceAgentCredentialError.invalidAPIKey
    }
    return trimmed
  }
}
