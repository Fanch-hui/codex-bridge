import BridgeIPC
import BridgeServiceAppCore
import XCTest

final class AgentModelCatalogResolutionTests: XCTestCase {
  func testProviderDefaultDoesNotBorrowAnotherModelsReasoning() {
    let models = [
      IPCAgentModelSummary(
        modelID: "reasoning", displayName: "Reasoning", supportedReasoningEfforts: ["high"],
        reasoningCapabilitiesAvailable: true, isDefaultModel: false),
      IPCAgentModelSummary(
        modelID: "default", displayName: "Default", supportedReasoningEfforts: [],
        reasoningCapabilitiesAvailable: true, isDefaultModel: true),
    ]
    let selected = AgentModelCatalogResolver.modelForSelection(modelID: nil, models: models)
    XCTAssertEqual(selected?.modelID, "default")
    XCTAssertEqual(selected?.supportedReasoningEfforts, [])
    XCTAssertEqual(
      AgentModelCatalogResolver.modelForSelection(modelID: "reasoning", models: models)?
        .supportedReasoningEfforts, ["high"])
  }

  func testMissingCapabilitiesDoNotClearAnExistingEffort() {
    let response = IPCAgentModelsResponse(models: [
      IPCAgentModelSummary(
        modelID: "pending", displayName: "Pending", supportedReasoningEfforts: [],
        reasoningCapabilitiesAvailable: false)
    ])
    let resolution = AgentModelCatalogResolver.resolve(
      previousOptions: [], catalogResponse: response, response: response,
      defaultModel: "pending", persistedEffort: "high", defaultWasRemoved: false)
    XCTAssertFalse(resolution.effortWasRemoved)
  }
}
