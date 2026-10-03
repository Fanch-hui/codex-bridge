import BridgeAgentCore
import Foundation

enum PiUsageNormalizer {
  static func supports(_ value: PiJSONValue?) -> Bool {
    guard let value, value["tokens"]?.objectValue != nil else { return false }
    return true
  }

  static func normalize(_ value: PiJSONValue?) throws -> AgentUsageStatistics? {
    guard let value, let tokens = value["tokens"]?.objectValue else { return nil }
    let context = value["contextUsage"]?.objectValue
    let statistics = try AgentUsageStatistics(
      inputTokens: try integer(tokens["input"]),
      outputTokens: try integer(tokens["output"]),
      cacheReadTokens: try integer(tokens["cacheRead"]),
      cacheWriteTokens: try integer(tokens["cacheWrite"]),
      totalTokens: try integer(tokens["total"]),
      contextTokens: try integer(context?["tokens"]),
      contextWindow: try integer(context?["contextWindow"]),
      costAmount: try number(value["cost"]),
      currency: nil
    )
    return hasValues(statistics) ? statistics : nil
  }

  private static func integer(_ value: PiJSONValue?) throws -> Int? {
    guard let value, value != .null else { return nil }
    guard let count = value.integerValue, count >= 0 else { throw PiRPCError.invalidRecord }
    return count
  }

  private static func number(_ value: PiJSONValue?) throws -> Double? {
    guard let value, value != .null else { return nil }
    guard let amount = value.doubleValue, amount.isFinite, amount >= 0 else {
      throw PiRPCError.invalidRecord
    }
    return amount
  }

  private static func hasValues(_ value: AgentUsageStatistics) -> Bool {
    value.inputTokens != nil || value.outputTokens != nil || value.cacheReadTokens != nil
      || value.cacheWriteTokens != nil || value.totalTokens != nil || value.contextTokens != nil
      || value.contextWindow != nil || value.costAmount != nil
  }
}
