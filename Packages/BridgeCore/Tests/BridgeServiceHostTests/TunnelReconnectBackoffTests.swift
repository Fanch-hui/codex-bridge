import XCTest

@testable import BridgeServiceHost

final class TunnelReconnectBackoffTests: XCTestCase {
  func testReconnectContinuesWithACappedDelay() {
    var backoff = TunnelReconnectBackoff([.seconds(1), .seconds(2), .seconds(4)])
    let expected = [1, 2, 4, 8, 16, 32, 60, 60]
    for seconds in expected {
      XCTAssertEqual(backoff.next(), .seconds(seconds))
    }
  }
}
