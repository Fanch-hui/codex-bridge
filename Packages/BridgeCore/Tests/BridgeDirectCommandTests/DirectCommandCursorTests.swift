import Foundation
import XCTest

@testable import BridgeDirectCommand

final class DirectCommandCursorTests: XCTestCase {
  func testCursorRetainsIncompleteChineseCharacterUntilNextChunk() {
    let collector = DirectCommandOutputCollector()
    collector.append(Data([0xE4, 0xB8]))
    let first = collector.delta(from: 0)
    XCTAssertEqual(first.text, "")
    XCTAssertEqual(first.nextOffset, 0)
    collector.append(Data([0xAD]))
    let next = collector.delta(from: first.nextOffset)
    XCTAssertEqual(next.text, "中")
    XCTAssertEqual(next.nextOffset, 3)
  }

  func testCursorPaginatesWithoutLosingOutput() {
    let collector = DirectCommandOutputCollector()
    let expected = String(repeating: "x", count: 40_000)
    collector.append(Data(expected.utf8))
    var offset = 0
    var actual = ""
    repeat {
      let delta = collector.delta(from: offset, final: true)
      actual += delta.text
      offset = delta.nextOffset
      if delta.reachedEnd { break }
    } while offset < expected.utf8.count
    XCTAssertEqual(actual, expected)
  }
}
