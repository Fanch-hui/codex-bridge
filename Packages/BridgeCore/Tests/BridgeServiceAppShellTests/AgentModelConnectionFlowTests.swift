import BridgeDesktopUI
import BridgeIPC
import XCTest

@testable import BridgeServiceAppShell

@MainActor
final class AgentModelConnectionFlowTests: XCTestCase {
  func testFirstConnectionLoadsModelsWithoutManualRefresh() async throws {
    let client = TestBridgeServiceClient()
    await client.configureAgentModels([option("first", efforts: ["high"])])
    let model = makeModel(client)
    await model.startAsync()
    model.connectAgentInstallation(providerID: "opencode")
    for _ in 0..<200 where model.agentModelOptions(for: "opencode").isEmpty {
      try await Task.sleep(for: .milliseconds(5))
    }
    XCTAssertEqual(model.agentModelOptions(for: "opencode").map(\.modelID), ["first"])
    await model.shutdownUI()
  }

  func testChangingAgentModelLoadsItsOwnEffortsThroughMainCatalogFlow() async throws {
    let client = TestBridgeServiceClient()
    let installation = IPCAgentInstallationSummary(
      installationID: "installation", providerID: "opencode", displayName: "OpenCode",
      executablePath: "/fixture/opencode", adapterRevision: 1, trustProfile: "managed",
      isEnabled: true, availability: "available", effectiveCapabilities: ["selection.model"],
      updatedAt: ""
    )
    await client.configureAgentInstallations([installation])
    await client.configureAgentModels([
      option("first", efforts: ["high"]), option("second", efforts: [], known: false),
    ])
    await client.configureAgentDefault("first")
    await client.configureSelectedModelResponse(
      "second",
      models: [option("first", efforts: ["high"]), option("second", efforts: ["low", "medium"])])
    let model = makeModel(client)
    await model.startAsync()
    for _ in 0..<200 where model.isRefreshingAgentModels(for: "opencode") {
      try await Task.sleep(for: .milliseconds(5))
    }
    BridgeDesktopCommandRouter.handle(
      BridgeDesktopCommandEnvelope(
        requestID: "select-model", command: .saveAgentDefault,
        payload: BridgeDesktopCommandPayload(
          providerID: "opencode", installationID: "installation", modelID: "second",
          permissionMode: "build"
        )), model: model
    )
    for _ in 0..<200
    where model.agentSelectedModel(for: "opencode")?
      .supportedReasoningEfforts != ["low", "medium"]
    {
      try await Task.sleep(for: .milliseconds(5))
    }
    let settings = BridgeDesktopUIStateBuilder.build(from: model).settings?.agentDefaults.first {
      $0.providerID == "opencode"
    }
    XCTAssertEqual(settings?.model, "second")
    XCTAssertEqual(settings?.effortOptions.map(\.id), ["low", "medium"])
    XCTAssertEqual(settings?.canSelectEffort, true)
    BridgeDesktopCommandRouter.handle(
      BridgeDesktopCommandEnvelope(
        requestID: "default-model-effort", command: .saveAgentDefault,
        payload: BridgeDesktopCommandPayload(
          providerID: "opencode", installationID: "installation",
          permissionMode: "build"
        )), model: model
    )
    for _ in 0..<200 where model.isRefreshingAgentModels(for: "opencode") {
      try await Task.sleep(for: .milliseconds(5))
    }
    BridgeDesktopCommandRouter.handle(
      BridgeDesktopCommandEnvelope(
        requestID: "save-default-effort", command: .saveAgentDefault,
        payload: BridgeDesktopCommandPayload(
          providerID: "opencode", installationID: "installation", effort: "high",
          permissionMode: "build"
        )), model: model
    )
    for _ in 0..<200 where model.agentModelDefault(for: "opencode").effort != "high" {
      try await Task.sleep(for: .milliseconds(5))
    }
    XCTAssertNil(model.agentModelDefault(for: "opencode").model)
    XCTAssertEqual(model.agentModelDefault(for: "opencode").effort, "high")
    await model.shutdownUI()
  }

  func testCachedModelSwitchPublishesEffortsImmediatelyWithoutAnotherQuery() async throws {
    let client = TestBridgeServiceClient()
    await client.configureAgentInstallations([
      IPCAgentInstallationSummary(
        installationID: "installation", providerID: "opencode", displayName: "OpenCode",
        executablePath: "/fixture/opencode", adapterRevision: 1, trustProfile: "managed",
        isEnabled: true, availability: "available", effectiveCapabilities: ["selection.model"],
        updatedAt: "")
    ])
    await client.configureAgentModels([
      option("first", efforts: ["high"]), option("second", efforts: ["low", "medium"]),
    ])
    await client.configureAgentDefault("first")
    let model = makeModel(client)
    await model.startAsync()
    for _ in 0..<200 where model.isRefreshingAgentModels(for: "opencode") {
      try await Task.sleep(for: .milliseconds(5))
    }
    let initialQueries = await client.agentModelsQueriesValue().count
    BridgeDesktopCommandRouter.handle(
      BridgeDesktopCommandEnvelope(
        requestID: "cached-model", command: .saveAgentDefault,
        payload: BridgeDesktopCommandPayload(
          providerID: "opencode", installationID: "installation", modelID: "second",
          permissionMode: "build"
        )), model: model
    )
    XCTAssertFalse(model.isRefreshingAgentModels(for: "opencode"))
    let settings = BridgeDesktopUIStateBuilder.build(from: model).settings?.agentDefaults.first {
      $0.providerID == "opencode"
    }
    XCTAssertEqual(settings?.model, "second")
    XCTAssertEqual(settings?.effortOptions.map(\.id), ["low", "medium"])
    await model.agentModelDefaultMutationTasks["opencode"]?.value
    let finalQueries = await client.agentModelsQueriesValue().count
    XCTAssertEqual(finalQueries, initialQueries)
    await model.shutdownUI()
  }

  private func option(_ id: String, efforts: [String], known: Bool = true) -> IPCAgentModelSummary {
    IPCAgentModelSummary(
      modelID: id, displayName: id, supportedReasoningEfforts: efforts,
      reasoningCapabilitiesAvailable: known)
  }

  private func makeModel(_ client: TestBridgeServiceClient) -> BridgeServiceAppModel {
    BridgeServiceAppModel(
      registration: ModelFlowRegistration(), clientFactory: { client }, pollInterval: nil,
      maximumConnectionAttempts: 1)
  }
}

@MainActor
private final class ModelFlowRegistration: BridgeServiceRegistrationManaging {
  var status: BridgeServiceRegistrationStatus { .enabled }
  func register() throws {}
  func unregister() async throws {}
  func openSystemSettings() {}
}
