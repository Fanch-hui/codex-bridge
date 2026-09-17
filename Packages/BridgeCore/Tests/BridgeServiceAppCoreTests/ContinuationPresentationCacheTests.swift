import BridgeIPC
import XCTest

@testable import BridgeServiceAppCore

final class ContinuationPresentationCacheTests: XCTestCase {
  func testNewTurnImmediatelyRetainsPriorConversationWithStablePrefixes() {
    var cache = TaskConversationPresentationCache()
    cache.store(
      TaskConversationPresentationSnapshot(
        entries: [
          .init(
            key: "turn-1:message", role: "agent", kind: "agent", content: "First reply",
            isFinal: true),
          .init(
            key: "message", role: "agent", kind: "agent", content: "Second reply", isFinal: true),
        ], canLoadEarlier: true), for: "turn-2"
    )
    let snapshot = cache.snapshot(for: "turn-3", priorTaskIDs: ["turn-1", "turn-2"])
    XCTAssertEqual(snapshot?.entries.map(\.key), ["turn-1:message", "turn-2:message"])
    XCTAssertEqual(snapshot?.entries.map(\.content), ["First reply", "Second reply"])
    XCTAssertTrue(snapshot?.canLoadEarlier == true)
    XCTAssertNil(cache.snapshot(for: "other-task", priorTaskIDs: []))
  }
}
