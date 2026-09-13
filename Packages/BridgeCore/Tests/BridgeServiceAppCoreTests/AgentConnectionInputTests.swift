import BridgeServiceAppCore
import XCTest

final class AgentConnectionInputTests: XCTestCase {
  func testConfigurationInputsTrimAndRejectInvalidValues() {
    XCTAssertEqual(
      AgentConnectionInput.baseURL(" https://api.example.test "), "https://api.example.test")
    XCTAssertEqual(AgentConnectionInput.apiKey(" key-1 "), "key-1")
    XCTAssertNil(AgentConnectionInput.baseURL("   "))
    XCTAssertNil(AgentConnectionInput.apiKey("\0"))
  }

  func testExistingConfigurationMayBeReusedOrReplacedAsAPair() {
    XCTAssertTrue(
      AgentConnectionInput.isValid(
        providerRequiresConfiguration: true,
        hasExistingInstallation: true,
        baseURL: nil,
        apiKey: nil
      )
    )
    XCTAssertTrue(
      AgentConnectionInput.isValid(
        providerRequiresConfiguration: true,
        hasExistingInstallation: true,
        baseURL: "https://api.example.test",
        apiKey: "key-1"
      )
    )
    XCTAssertFalse(
      AgentConnectionInput.isValid(
        providerRequiresConfiguration: true,
        hasExistingInstallation: true,
        baseURL: "https://api.example.test",
        apiKey: nil
      )
    )
    XCTAssertFalse(
      AgentConnectionInput.isValid(
        providerRequiresConfiguration: true,
        hasExistingInstallation: false,
        baseURL: nil,
        apiKey: nil
      )
    )
  }
}
