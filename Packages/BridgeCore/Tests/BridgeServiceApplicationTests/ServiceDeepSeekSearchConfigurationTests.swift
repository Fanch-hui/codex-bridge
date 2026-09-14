import BridgeServiceApplication
import BridgeServiceCore
import XCTest

final class ServiceDeepSeekSearchConfigurationTests: XCTestCase {
  func testSavedSearchEndpointSurvivesReloadAndDoesNotChangeChatCredentials() async throws {
    let store = try SimpleServiceStore.inMemory()
    let settings = ServiceSettings(store: store)
    let configuration = ServiceDeepSeekSearchConfiguration(settings: settings)
    let saved = try await configuration.save(baseURL: " https://search.example.test/anthropic/v1/ ")
    XCTAssertEqual(saved, "https://search.example.test/anthropic/v1")
    let reloaded = ServiceDeepSeekSearchConfiguration(settings: ServiceSettings(store: store))
    let environment = try await reloaded.applying(to: [
      "DEEPSEEK_BASE_URL": "https://chat.example.test/v1",
      "DEEPSEEK_API_KEY": "fixture-key",
    ])
    XCTAssertEqual(environment["DEEPSEEK_SEARCH_BASE_URL"], saved)
    XCTAssertEqual(environment["DEEPSEEK_BASE_URL"], "https://chat.example.test/v1")
    XCTAssertEqual(environment["DEEPSEEK_API_KEY"], "fixture-key")
    _ = try await reloaded.save(baseURL: "")
    let cleared = try await reloaded.applying(to: [:])
    XCTAssertNil(cleared["DEEPSEEK_SEARCH_BASE_URL"])
  }
}
