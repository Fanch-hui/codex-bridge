import BridgeMCP
import BridgeServiceApplication
import BridgeServiceCore
import Foundation
import XCTest

final class ModelDefaultProjectionTests: XCTestCase {
  func testModelListsReflectConfiguredExecutionDefault() async throws {
    let fixture = try await makeServiceApplicationFixture(self)
    let application = makeServiceApplication(
      fixture: fixture,
      catalogScript: serviceModelCatalogScript
    )
    try await fixture.settings.setModelPreferences(
      ServiceModelPreferences(
        executionModel: "gpt-5.6-luna",
        executionEffort: "medium",
        supervisorModel: "",
        supervisorEffort: ""
      )
    )

    let models = try await application.serviceModels(
      deadline: ContinuousClock.now.advanced(by: .seconds(10))
    ).models
    XCTAssertEqual(models.filter(\.isDefault).map(\.modelID), ["gpt-5.6-luna"])
    XCTAssertEqual(models.first(where: \.isDefault)?.defaultReasoningEffort, "medium")
  }
}
