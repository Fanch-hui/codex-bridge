import Foundation
import XCTest

@testable import BridgeDeepSeekHarnessACP

final class DeepSeekHarnessACPRemoteModelsTests: XCTestCase {
  func testRemoteCatalogPreservesProviderIDsAndOrder() throws {
    let data = Data(
      #"{"data":[{"id":"dsv4pro"},{"id":"vendor/model"},{"id":"dsv4pro"},{"id":"gpt-example"}]}"#
        .utf8)
    XCTAssertEqual(
      try DeepSeekHarnessACPRemoteModels.decode(data), ["dsv4pro", "vendor/model", "gpt-example"])
  }

  func testUnusableCatalogDoesNotBecomeBuiltinModels() {
    for response in [#"{"data":[]}"#, #"{"error":{"message":"private details"}}"#] {
      XCTAssertThrowsError(try DeepSeekHarnessACPRemoteModels.decode(Data(response.utf8))) {
        error in
        XCTAssertFalse(error.localizedDescription.contains("private details"))
      }
    }
  }
}
