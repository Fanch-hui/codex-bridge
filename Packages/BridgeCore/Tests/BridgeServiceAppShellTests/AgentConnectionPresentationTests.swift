import BridgeIPC
import XCTest

@testable import BridgeServiceAppShell

@MainActor
final class AgentConnectionPresentationTests: XCTestCase {
  func testConnectedAgentActionsReflectBusyAndServiceState() {
    let model = makeModel()
    model.connectionState = .connected
    model.agentInstallations = [
      IPCAgentInstallationSummary(
        installationID: "fixture", providerID: "opencode", displayName: "OpenCode",
        executablePath: "/fixture/opencode", adapterRevision: 1, trustProfile: "managed",
        isEnabled: true, availability: "available", effectiveCapabilities: [], updatedAt: ""
      )
    ]
    let ready = BridgeDesktopUIStateBuilder.build(from: model).connections?.installations.first
    XCTAssertEqual(ready?.enabled, true)
    XCTAssertEqual(ready?.canReprobe, true)
    model.isManagingAgents = true
    let busy = BridgeDesktopUIStateBuilder.build(from: model).connections?.installations.first
    XCTAssertEqual(busy?.enabled, true)
    XCTAssertEqual(busy?.canToggle, false)
    XCTAssertEqual(busy?.canReprobe, false)
    XCTAssertEqual(busy?.canRemove, false)
    model.isManagingAgents = false
    model.connectionState = .unavailable
    let offline = BridgeDesktopUIStateBuilder.build(from: model).connections?.installations.first
    XCTAssertEqual(offline?.canReprobe, false)
  }

  func testCachedModelsDoNotReportCodexConnectedWhenServiceIsOffline() async {
    let model = makeModel()
    await model.startAsync()
    XCTAssertEqual(
      BridgeDesktopUIStateBuilder.build(from: model).connections?.codex?.isConnected, true)
    model.connectionState = .unavailable
    XCTAssertFalse(model.models.isEmpty)
    XCTAssertEqual(
      BridgeDesktopUIStateBuilder.build(from: model).connections?.codex?.isConnected, false)
    await model.shutdownUI()
  }

  func testDiscoveryPreservesExistingConfigurationWithoutRegistering() {
    let model = makeModel()
    model.connectionState = .connected
    model.agentProviders = [
      IPCAgentProviderSummary(
        providerID: "deepseek-harness", displayName: "DeepSeek Harness", adapterRevision: 1,
        discoveryState: "discovered", discoveredExecutablePath: "/fixture/dsh.js",
        discoveredConfigurationPath: "/fixture/cordis.yml",
        configuredBaseURL: "https://dsh.example",
        requiresConfiguration: true
      )
    ]
    let page = BridgeDesktopUIStateBuilder.build(from: model).connections
    XCTAssertEqual(page?.providers.first?.discoveryState, "discovered")
    XCTAssertEqual(page?.providers.first?.discoveredConfigurationPath, "/fixture/cordis.yml")
    XCTAssertEqual(page?.providers.first?.configuredBaseURL, "https://dsh.example")
    XCTAssertEqual(page?.installations.count, 0)
    XCTAssertEqual(page?.canRegisterAgent, true)
  }

  func testImmediateOperationFailurePublishesCompletion() async throws {
    let model = makeModel()
    model.connectionState = .connected
    model.removeAgentInstallation("fixture")
    for _ in 0..<100 where model.agentOperationRevision == 0 {
      try await Task.sleep(for: .milliseconds(1))
    }
    XCTAssertEqual(model.agentOperationRevision, 1)
    XCTAssertFalse(model.isManagingAgents)
    XCTAssertNotNil(model.errorMessage)
    XCTAssertEqual(
      BridgeDesktopUIStateBuilder.build(from: model).connections?.agentOperationRevision, 1
    )
  }

  private func makeModel() -> BridgeServiceAppModel {
    BridgeServiceAppModel(
      registration: AgentPresentationRegistration(),
      clientFactory: { TestBridgeServiceClient() },
      pollInterval: nil,
      maximumConnectionAttempts: 1
    )
  }
}

@MainActor
private final class AgentPresentationRegistration: BridgeServiceRegistrationManaging {
  var status: BridgeServiceRegistrationStatus { .enabled }
  func register() throws {}
  func unregister() async throws {}
  func openSystemSettings() {}
}
