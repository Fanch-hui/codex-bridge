import BridgeACP
import BridgeServiceCore
import Foundation

struct GatewayDeadlineSettings: Sendable {
  let requestSeconds: Int
  let streamIdleSeconds: Int
  static let defaults = Self(requestSeconds: 900, streamIdleSeconds: 180)

  private init(requestSeconds: Int, streamIdleSeconds: Int) {
    self.requestSeconds = requestSeconds
    self.streamIdleSeconds = streamIdleSeconds
  }

  init(payload: ACPJSONValue) throws {
    guard let request = payload["requestSeconds"]?.intValue,
      let idle = payload["streamIdleSeconds"]?.intValue,
      (1...86400).contains(request), (1...86400).contains(idle)
    else { throw ServiceStoreError.invalidArgument("gateway.deadlines") }
    self.init(requestSeconds: request, streamIdleSeconds: idle)
  }

  var presentation: ACPJSONValue {
    .object([
      "requestSeconds": .integer(Int64(requestSeconds)),
      "streamIdleSeconds": .integer(Int64(streamIdleSeconds)),
    ])
  }
}

extension ServiceProviderGateway {
  func recentActivity() async throws -> [ACPJSONValue] {
    try await store.recentGatewayActivity().map {
      try JSONDecoder().decode(ACPJSONValue.self, from: Data($0.utf8))
    }
  }

  /// Recomputed only after a new record, since status is read far more often than written.
  func activitySummary() async throws -> ACPJSONValue {
    if let activitySummaryCache { return activitySummaryCache }
    let summary = ACPJSONValue.array(
      try await store.gatewayActivitySummary().map { item in
        .object([
          "providerID": .string(item.providerID), "model": .string(item.model),
          "requests": .integer(Int64(item.requests)), "failed": .integer(Int64(item.failed)),
          "measured": .integer(Int64(item.measured)),
          "inputTokens": .integer(Int64(item.inputTokens)),
          "outputTokens": .integer(Int64(item.outputTokens)),
          "reasoningTokens": .integer(Int64(item.reasoningTokens)),
          "cacheableInputTokens": .integer(Int64(item.cacheableInputTokens)),
          "cacheReadTokens": .integer(Int64(item.cacheReadTokens)),
        ])
      })
    activitySummaryCache = summary
    return summary
  }

  func appendActivity(_ entry: ACPJSONValue) async {
    activitySummaryCache = nil
    do {
      try await store.appendGatewayActivity(String(decoding: entry.encodedData(), as: UTF8.self))
      activityError = nil
    } catch {
      activityError = "请求记录保存失败；模型响应不受影响。"
    }
  }
}
