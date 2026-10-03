import Foundation

/// An authoritative provider snapshot; cumulative tokens are not context occupancy.
public struct AgentUsageStatistics: Codable, Equatable, Sendable {
  public let inputTokens: Int?
  public let outputTokens: Int?
  public let cacheReadTokens: Int?
  public let cacheWriteTokens: Int?
  public let totalTokens: Int?
  public let contextTokens: Int?
  public let contextWindow: Int?
  public let contextUsedPercentage: Double?
  public let costAmount: Double?
  public let currency: String?

  public init(
    inputTokens: Int? = nil, outputTokens: Int? = nil,
    cacheReadTokens: Int? = nil, cacheWriteTokens: Int? = nil,
    totalTokens: Int? = nil, contextTokens: Int? = nil, contextWindow: Int? = nil,
    costAmount: Double? = nil, currency: String? = nil,
    contextUsedPercentage: Double? = nil
  ) throws {
    let counts = [
      inputTokens, outputTokens, cacheReadTokens, cacheWriteTokens,
      totalTokens, contextTokens, contextWindow,
    ].compactMap { $0 }
    guard counts.allSatisfy({ $0 >= 0 }),
      costAmount.map({ $0.isFinite && $0 >= 0 }) ?? true,
      contextUsedPercentage.map({ $0.isFinite && (0...100).contains($0) }) ?? true,
      currency == nil || costAmount != nil
    else { throw AgentRuntimeError.invalidRequest("usage.statistics") }
    try AgentValidation.optionalIdentifier(currency, field: "usage.currency", maximumBytes: 16)
    self.inputTokens = inputTokens
    self.outputTokens = outputTokens
    self.cacheReadTokens = cacheReadTokens
    self.cacheWriteTokens = cacheWriteTokens
    self.totalTokens = totalTokens
    self.contextTokens = contextTokens
    self.contextWindow = contextWindow
    self.contextUsedPercentage = contextUsedPercentage
    self.costAmount = costAmount
    self.currency = currency
  }
}
