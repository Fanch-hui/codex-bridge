import BridgeAgentCore
import BridgeSecurity
import BridgeServiceApplication
import Foundation
import XCTest

final class ServiceAgentCredentialEnvironmentTests: XCTestCase {
  func testStoredCredentialsAreScopedToManagedConfiguration() async throws {
    let secretStore = CredentialTestSecretStore()
    let configurationPath = FileManager.default.temporaryDirectory
      .appendingPathComponent("managed-\(UUID().uuidString)", isDirectory: true)
      .appendingPathComponent("cordis.yml").path
    let environment = ServiceAgentCredentialEnvironment(
      secretStore: secretStore,
      sourceEnvironment: [
        "DEEPSEEK_API_KEY": "ambient-value",
        "DEEPSEEK_BASE_URL": "https://ambient.example",
        "PATH": "/usr/bin",
      ]
    )
    try await environment.configureDeepSeekHarness(
      baseURL: " https://managed.example/v1 ",
      apiKey: "fixture-api-key",
      configurationPath: configurationPath
    )

    let managed = try makeInstallation(configurationPath: configurationPath)
    let manual = try makeInstallation(
      configurationPath: configurationPath + ".manual"
    )
    let managedEnvironment = try await environment.runtimeEnvironment(for: managed)
    let manualEnvironment = try await environment.runtimeEnvironment(for: manual)

    XCTAssertEqual(managedEnvironment["DEEPSEEK_API_KEY"], "fixture-api-key")
    XCTAssertEqual(managedEnvironment["DEEPSEEK_BASE_URL"], "https://managed.example/v1")
    XCTAssertNil(manualEnvironment["DEEPSEEK_API_KEY"])
    XCTAssertNil(manualEnvironment["DEEPSEEK_BASE_URL"])
    XCTAssertEqual(secretStore.count(), 1)
  }

  private func makeInstallation(configurationPath: String) throws -> AgentInstallation {
    let canonicalPath = URL(fileURLWithPath: configurationPath)
      .standardizedFileURL.path
    let artifact = AgentInstallationArtifact(
      role: .launchConfiguration,
      canonicalPath: canonicalPath,
      device: 1,
      inode: 1,
      fileSize: 1,
      modificationTimeNanoseconds: 0,
      sha256: String(repeating: "0", count: 64)
    )
    return try AgentInstallation(
      id: AgentInstallationID(rawValue: "ainst-credential-test"),
      providerID: .deepSeekHarness,
      executablePath: "/tmp/deepseek-harness/bin.js",
      artifacts: [artifact]
    )
  }
}

private final class CredentialTestSecretStore: SecretStore, @unchecked Sendable {
  private let lock = NSLock()
  private var values: [SecretReference: Data] = [:]

  func store(_ secret: Data, for reference: SecretReference) throws {
    lock.withLock { values[reference] = secret }
  }

  func load(_ reference: SecretReference) throws -> Data {
    guard let value = lock.withLock({ values[reference] }) else {
      throw SecretStoreError.notFound
    }
    return value
  }

  func remove(_ reference: SecretReference) throws {
    lock.withLock { values.removeValue(forKey: reference) }
  }

  func count() -> Int {
    lock.withLock { values.count }
  }
}
