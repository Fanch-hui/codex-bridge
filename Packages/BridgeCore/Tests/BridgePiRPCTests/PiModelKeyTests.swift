import Foundation
import Testing

@testable import BridgePiRPC

struct PiModelKeyTests {
  @Test func preservesProviderAndModelIdentity() throws {
    let key = try PiModelKey(provider: "provider/one", modelID: "family/model-模型")
    #expect(try PiModelKey(rawValue: key.encoded()) == key)
  }

  @Test func separatorCollisionsRemainDistinct() throws {
    let first = try PiModelKey(provider: "a/b", modelID: "c")
    let second = try PiModelKey(provider: "a", modelID: "b/c")
    #expect(try first.encoded() != second.encoded())
  }

  @Test func rejectsEmptyControlAndOversizedValues() {
    #expect(throws: (any Error).self) { try PiModelKey(provider: "", modelID: "a") }
    #expect(throws: (any Error).self) { try PiModelKey(provider: "a", modelID: "b\n") }
    #expect(throws: (any Error).self) {
      try PiModelKey(provider: "a", modelID: String(repeating: "x", count: 256))
    }
  }

  @Test func rejectsMalformedAndNonCanonicalIDs() throws {
    #expect(throws: (any Error).self) { try PiModelKey(rawValue: "model-only") }
    #expect(throws: (any Error).self) { try PiModelKey(rawValue: "pi:!!!!") }
    let value = try PiModelKey(provider: "a", modelID: "b").encoded()
    #expect(throws: (any Error).self) { try PiModelKey(rawValue: value + "=") }
  }
}
