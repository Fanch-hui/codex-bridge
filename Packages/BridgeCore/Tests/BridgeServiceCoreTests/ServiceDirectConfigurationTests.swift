import BridgeServiceCore
import XCTest

final class ServiceDirectConfigurationTests: XCTestCase {
  func testGlobalConfigurationPersistsIndependentlyOfProjects() async throws {
    let fixture = try ServiceCoreFixture()
    defer { fixture.remove() }
    let settings = ServiceSettings(store: try SimpleServiceStore(path: fixture.databasePath))
    let initial = try await settings.directConfiguration()
    XCTAssertNil(initial)
    let value = ServiceDirectConfiguration(
      allowedCommands: ["npm test"], deniedCommands: ["git push"])
    try await settings.setDirectConfiguration(value)
    let reopened = ServiceSettings(store: try SimpleServiceStore(path: fixture.databasePath))
    let saved = try await reopened.directConfiguration()
    XCTAssertEqual(saved, value)
  }
}
