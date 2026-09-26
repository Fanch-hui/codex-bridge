import BridgeACP
import BridgeAgentCore
import Foundation

struct QoderEventNormalizer {
  func normalize(_ value: QoderJSONValue) throws -> AgentEvent? {
    switch value["kind"]?.stringValue {
    case "content":
      guard let key = value["key"]?.stringValue, let content = value["text"]?.stringValue,
        let mode = value["mode"]?.stringValue.flatMap(AgentContentMode.init(rawValue:)),
        let kind = value["contentKind"]?.stringValue.flatMap(AgentContentKind.init(rawValue:)),
        let final = value["final"]?.boolValue
      else { throw ACPError.invalidMessage }
      return .content(
        try AgentContentUpdate(
          key: key, role: .assistant, kind: kind,
          mode: mode, content: content, isFinal: final, authoritative: mode == .full))
    case "tool":
      guard let key = value["key"]?.stringValue, let name = value["name"]?.stringValue,
        let status = value["status"]?.stringValue.flatMap(AgentToolStatus.init(rawValue:))
      else { throw ACPError.invalidMessage }
      return .tool(
        try AgentToolUpdate(
          key: key, name: name, status: status,
          arguments: value["arguments"]?.stringValue, output: value["output"]?.stringValue))
    case "child":
      guard let id = value["id"]?.stringValue else { throw ACPError.invalidMessage }
      let status = value["status"]?.stringValue
      let child = try AgentChildRun(
        id: id, name: value["name"]?.stringValue,
        status: status, summary: value["summary"]?.stringValue)
      let toolStatus: AgentToolStatus
      switch status {
      case "completed": toolStatus = .completed
      case "failed": toolStatus = .failed
      case "stopped": toolStatus = .cancelled
      default: toolStatus = .inProgress
      }
      return .tool(
        try AgentToolUpdate(
          key: "qoder-child-" + id, name: "Agent",
          status: toolStatus, childRuns: [child]))
    case "plan":
      guard let values = value["entries"]?.arrayValue, values.count <= 128 else {
        throw ACPError.invalidMessage
      }
      let entries = try values.map { item -> AgentPlanEntry in
        guard let content = item["content"]?.stringValue else { throw ACPError.invalidMessage }
        return try AgentPlanEntry(content: content, status: item["status"]?.stringValue)
      }
      return .plan(entries)
    case "usage_statistics":
      guard let value = value["statistics"] else { throw ACPError.invalidMessage }
      return .usageStatistics(
        try AgentUsageStatistics(
          inputTokens: value["inputTokens"]?.intValue,
          outputTokens: value["outputTokens"]?.intValue,
          cacheReadTokens: value["cacheReadTokens"]?.intValue,
          cacheWriteTokens: value["cacheWriteTokens"]?.intValue,
          totalTokens: value["totalTokens"]?.intValue,
          contextTokens: value["contextTokens"]?.intValue,
          contextWindow: value["contextWindow"]?.intValue,
          costAmount: value["costAmount"]?.doubleValue,
          currency: value["currency"]?.stringValue,
          contextUsedPercentage: value["contextUsedPercentage"]?.doubleValue))
    case "completed":
      guard let summary = value["summary"]?.stringValue, !summary.isEmpty else {
        throw ACPError.invalidMessage
      }
      return .completed(summary: summary, stopReason: value["stopReason"]?.stringValue)
    case "interrupted": return .interrupted
    case "failed":
      let code = value["code"]?.stringValue ?? "execution_failed"
      guard code.utf8.count <= 128 else { throw ACPError.invalidMessage }
      if code == "authentication_required" {
        return .failed(
          code: "qoder_" + code,
          summary: "Qoder 当前地区登录已失效，请使用该地区原生 CLI 登录后继续。")
      }
      return .failed(code: "qoder_" + code, summary: "Qoder 执行未完成：\(code)")
    case "input_dispatched": return nil
    default: throw ACPError.invalidMessage
    }
  }
}
