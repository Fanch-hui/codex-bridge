import BridgeAgentCore
import Foundation
import Testing

@testable import BridgePiRPC

struct PiUsageNormalizerTests {
  @Test func mapsCumulativeAndCurrentContextWithoutChangingTheirMeaning() throws {
    let response = PiJSONValue.object([
      "tokens": .object([
        "input": .integer(50_000), "output": .integer(10_000),
        "cacheRead": .integer(40_000), "cacheWrite": .integer(5_000),
        "total": .integer(105_000),
      ]),
      "cost": .number(0.45),
      "contextUsage": .object(["tokens": .integer(60_000), "contextWindow": .integer(200_000)]),
    ])
    let parsed = try PiUsageNormalizer.normalize(response)
    let usage = try #require(parsed)
    let expected = try AgentUsageStatistics(
      inputTokens: 50_000, outputTokens: 10_000,
      cacheReadTokens: 40_000, cacheWriteTokens: 5_000, totalTokens: 105_000,
      contextTokens: 60_000, contextWindow: 200_000, costAmount: 0.45)

    #expect(usage == expected)
  }

  @Test func keepsUnknownContextFieldsUnknownAfterCompaction() throws {
    let response = PiJSONValue.object([
      "tokens": .object(["total": .integer(12)]),
      "contextUsage": .object(["tokens": .null, "contextWindow": .integer(64_000)]),
    ])
    let parsed = try PiUsageNormalizer.normalize(response)
    let usage = try #require(parsed)
    #expect(usage.totalTokens == 12)
    #expect(usage.contextTokens == nil)
    #expect(usage.contextWindow == 64_000)
    #expect(usage.costAmount == nil)
    #expect(usage.currency == nil)
  }

  @Test func rejectsMalformedStatisticsAndIgnoresMissingData() throws {
    #expect(throws: PiRPCError.invalidRecord) {
      try PiUsageNormalizer.normalize(.object(["tokens": .object(["total": .integer(-1)])]))
    }
    let zeroUsage = try PiUsageNormalizer.normalize(
      .object([
        "tokens": .object(["total": .integer(0)])
      ]))
    #expect(zeroUsage != nil)
    #expect(try PiUsageNormalizer.normalize(nil) == nil)
    #expect(PiUsageNormalizer.supports(.object(["tokens": .object(["total": .integer(0)])])))
    #expect(!PiUsageNormalizer.supports(.object(["cost": .number(0.1)])))
  }
}
