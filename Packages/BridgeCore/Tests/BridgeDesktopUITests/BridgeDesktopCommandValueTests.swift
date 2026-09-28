import BridgeDesktopUI
import XCTest

final class BridgeDesktopCommandValueTests: XCTestCase {
  func testNonEmptyTrimsBeforeCountingUTF8Bytes() {
    XCTAssertEqual(BridgeDesktopCommandValue.nonEmpty("  id-1  ", maximumUTF8Bytes: 4), "id-1")
    XCTAssertNil(BridgeDesktopCommandValue.nonEmpty("é", maximumUTF8Bytes: 1))
    XCTAssertNil(BridgeDesktopCommandValue.nonEmpty("id\0", maximumUTF8Bytes: 8))
  }

  func testTextAndPathValidationPreserveInputAndRejectInvalidBytes() {
    XCTAssertEqual(BridgeDesktopCommandValue.text("  value  ", maximumUTF8Bytes: 9), "  value  ")
    XCTAssertEqual(
      BridgeDesktopCommandValue.nonBlankText("  secret  ", maximumUTF8Bytes: 10), "  secret  "
    )
    XCTAssertNil(BridgeDesktopCommandValue.nonBlankText(" \n ", maximumUTF8Bytes: 8))
    XCTAssertNil(BridgeDesktopCommandValue.nonBlankText("secret\0", maximumUTF8Bytes: 8))
    XCTAssertNil(BridgeDesktopCommandValue.text("é", maximumUTF8Bytes: 1))
    XCTAssertNil(BridgeDesktopCommandValue.pathText("C:\\app\0.exe", maximumUTF8Bytes: 32))
    XCTAssertNil(BridgeDesktopCommandValue.pathText("/long", maximumUTF8Bytes: 4))
  }

  func testQoderDistributionAcceptsOnlySupportedValues() {
    XCTAssertEqual(BridgeDesktopCommandValue.qoderDistribution(" cn "), "cn")
    XCTAssertEqual(BridgeDesktopCommandValue.qoderDistribution("international"), "international")
    XCTAssertNil(BridgeDesktopCommandValue.qoderDistribution("other"))
  }

  func testCommandArgumentsEnforceCountAndByteLimits() {
    XCTAssertEqual(
      BridgeDesktopCommandValue.arguments(
        ["--flag", "值"], maximumCount: 2, maximumUTF8BytesPerArgument: 6),
      ["--flag", "值"]
    )
    XCTAssertNil(
      BridgeDesktopCommandValue.arguments(
        ["one", "two"], maximumCount: 1, maximumUTF8BytesPerArgument: 4)
    )
    XCTAssertNil(
      BridgeDesktopCommandValue.arguments(["é"], maximumCount: 1, maximumUTF8BytesPerArgument: 1)
    )
    XCTAssertNil(
      BridgeDesktopCommandValue.arguments(
        ["bad\0arg"], maximumCount: 1, maximumUTF8BytesPerArgument: 16)
    )
  }
}
