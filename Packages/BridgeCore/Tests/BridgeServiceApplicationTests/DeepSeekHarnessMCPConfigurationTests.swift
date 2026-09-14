import BridgeAgentCore
import BridgeSecurity
import BridgeServiceApplication
import BridgeServiceCore
import Foundation
import XCTest

final class DeepSeekHarnessMCPConfigurationTests: XCTestCase {
  func testSaveRedactsSecretsAndResolvesEnabledRuntimeConfiguration() async throws {
    let store = try SimpleServiceStore.inMemory()
    let secrets = DeepSeekHarnessMCPTestSecretStore()
    let configuration = ServiceDeepSeekHarnessMCPConfiguration(
      settings: ServiceSettings(store: store), secretStore: secrets
    )
    _ = try await configuration.save(
      ServiceDeepSeekHarnessMCPServerInput(
        id: "local-tools",
        name: "Local tools",
        enabled: true,
        transport: .stdio,
        command: "/usr/bin/npx",
        args: ["server"],
        environment: [
          ServiceDeepSeekHarnessMCPSecretInput(name: "API_TOKEN", value: "fixture-secret")
        ]
      )
    )

    let listed = try await configuration.list()
    XCTAssertEqual(
      listed.first?.environment,
      [
        ServiceDeepSeekHarnessMCPSecretSummary(name: "API_TOKEN", hasValue: true)
      ])
    let runtime = try await configuration.enabledRuntimeConfigurations()
    XCTAssertEqual(runtime.first?.transport, .stdio)
    XCTAssertEqual(runtime.first?.environment["API_TOKEN"], "fixture-secret")
    XCTAssertEqual(secrets.values.count, 1)
  }

  func testEmptySecretRetainsValueAndOmittingFieldRemovesIt() async throws {
    let store = try SimpleServiceStore.inMemory()
    let secrets = DeepSeekHarnessMCPTestSecretStore()
    let configuration = ServiceDeepSeekHarnessMCPConfiguration(
      settings: ServiceSettings(store: store), secretStore: secrets
    )
    let base = ServiceDeepSeekHarnessMCPServerInput(
      id: "remote-tools",
      name: "Remote tools",
      enabled: true,
      transport: .http,
      url: "https://mcp.example.test/mcp?mode=tools",
      headers: [ServiceDeepSeekHarnessMCPSecretInput(name: "Authorization", value: "Bearer one")]
    )
    _ = try await configuration.save(base)
    _ = try await configuration.save(
      ServiceDeepSeekHarnessMCPServerInput(
        id: base.id,
        name: base.name,
        enabled: base.enabled,
        transport: base.transport,
        url: base.url,
        headers: [ServiceDeepSeekHarnessMCPSecretInput(name: "Authorization", value: "")]
      )
    )
    let retained = try await configuration.enabledRuntimeConfigurations()
    XCTAssertEqual(retained.first?.headers["Authorization"], "Bearer one")

    _ = try await configuration.save(
      ServiceDeepSeekHarnessMCPServerInput(
        id: base.id,
        name: base.name,
        enabled: base.enabled,
        transport: base.transport,
        url: base.url
      )
    )
    XCTAssertEqual(secrets.values.count, 0)
  }

  func testDeleteRemovesMetadataAndSecret() async throws {
    let store = try SimpleServiceStore.inMemory()
    let secrets = DeepSeekHarnessMCPTestSecretStore()
    let configuration = ServiceDeepSeekHarnessMCPConfiguration(
      settings: ServiceSettings(store: store), secretStore: secrets
    )
    _ = try await configuration.save(
      ServiceDeepSeekHarnessMCPServerInput(
        id: "delete-me",
        name: "Delete me",
        enabled: false,
        transport: .http,
        url: "https://mcp.example.test/mcp?mode=tools",
        headers: [ServiceDeepSeekHarnessMCPSecretInput(name: "X-Key", value: "fixture")]
      )
    )
    try await configuration.delete(id: "delete-me")
    let listed = try await configuration.list()
    XCTAssertTrue(listed.isEmpty)
    XCTAssertTrue(secrets.values.isEmpty)
  }
}

private final class DeepSeekHarnessMCPTestSecretStore: SecretStore, @unchecked Sendable {
  var values: [SecretReference: Data] = [:]

  func store(_ secret: Data, for reference: SecretReference) throws {
    values[reference] = secret
  }

  func load(_ reference: SecretReference) throws -> Data {
    guard let value = values[reference] else { throw SecretStoreError.notFound }
    return value
  }

  func remove(_ reference: SecretReference) throws {
    values.removeValue(forKey: reference)
  }
}
