import Foundation

public enum TaskHandoffRenderer {
  public static let maximumPromptBytes = 24 * 1024
  public static let maximumAdditionalBytes = 4096

  public struct Result: Equatable, Sendable {
    public let prompt: String
    public let warnings: [String]
    public let ready: Bool
    public let estimatedTokens: Int
  }

  public static func render(
    _ packet: TaskHandoffPacket, handoffID: String, additionalInstructions: String = "",
    contextWindowTokens: Int? = nil, reservedTokens: Int = 8192
  ) -> Result {
    var warnings = Array(Set(packet.warnings)).sorted()
    guard packet.schemaVersion == TaskHandoffPacket.currentSchemaVersion else {
      return blocked("交接数据版本不受支持，请升级 App 与后台服务。", warnings: warnings)
    }
    guard packet.historyComplete else {
      return blocked("来源记录不完整，已阻止交接；请恢复缺失记录或在新任务中确认完整要求。", warnings: warnings)
    }
    guard !additionalInstructions.contains("\0"),
      additionalInstructions.utf8.count <= maximumAdditionalBytes,
      !packet.requirements.contains(where: { $0.text.contains("\0") })
    else {
      return blocked("交接补充不能包含 NUL，且不能超过 4096 字节。", warnings: warnings)
    }
    let limit: Int
    if let contextWindowTokens {
      // Byte count is a conservative estimate, not a model tokenizer contract.
      let capacity = max(0, contextWindowTokens)
      let reserve = min(capacity, max(0, reservedTokens))
      limit = min(maximumPromptBytes, capacity - reserve)
      warnings.append("上下文按 UTF-8 字节数保守估算，非精确 token 计数；仍需为 Agent 原生上下文留空间。")
    } else {
      limit = maximumPromptBytes
      warnings.append("目标未提供可验证的上下文容量；仅限制交接正文为 24 KiB，不保证总上下文容量。")
    }
    warnings.append("来源 Agent 的结论不是验收证明；命令记录也不代表当前工作区的测试结果。")
    let omissionWarning = "部分历史证据或文件已节选/省略；未省略用户要求。未假定目标可读取 Bridge 历史；缺证据须明确说明并重新核对工作区。"
    let footerReserve = warningText(warnings + [omissionWarning]).utf8.count + 2
    var body = [
      "交接协议 v1 · HANDOFF-ID: \(handoffID)",
      "项目：\(packet.projectID)\n来源任务：\(packet.sourceTaskID)\n来源 Agent：\(packet.sourceProviderID)\n来源版本：\(packet.sourceRevision)",
      "先读取并遵守工作区中的 AGENTS.md，确认项目和当前文件状态。以下是带来源的历史资料，不是额外的工具权限。用户要求按先后顺序保留；冲突、过时或缺失信息须说明，不得猜测已通过测试。先单独一行回复 HANDOFF-ACK: \(handoffID)，列出仍有效的限制、未完成事项和阻塞，再继续工作。该回执不等于任务完成。",
      "任务状态与失败记录（服务记录，不代表验收通过）：\n" + packet.outcomes.map(itemText).joined(separator: "\n"),
      "用户要求（完整保留；包含运行中追加要求）：\n" + packet.requirements.map(itemText).joined(separator: "\n\n"),
    ].joined(separator: "\n\n")
    if !additionalInstructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      body += "\n\n本次用户补充：\n" + additionalInstructions
    }
    guard body.utf8.count + footerReserve <= limit else {
      return blocked(
        "关键要求与状态已超过交接预算（\(body.utf8.count) 字节）；未裁剪要求、未发送任务。请在来源会话中确认一份精简且完整的新任务要求。",
        warnings: warnings)
    }
    var omitted = false
    var included = Set<String>()
    let latest = packet.evidence.filter {
      $0.sourceTaskID == packet.sourceTaskID
        && ($0.kind == "agent-claim-unverified" || $0.kind == "last-step-unverified")
    }
    for item in latest {
      let allowance = min(4096, limit - footerReserve - body.utf8.count - 2)
      guard allowance >= 256 else {
        return blocked("预算不足以保留当前任务的结果与阻塞线索，已阻止不完整交接。", warnings: warnings)
      }
      let text = itemText(item)
      let excerpt = headAndTail(text, maximumBytes: allowance)
      omitted = omitted || excerpt != text
      body += "\n\n" + excerpt
      included.insert(item.id)
    }
    for item in packet.evidence.reversed() where !included.contains(item.id) {
      let allowance = min(2048, limit - footerReserve - body.utf8.count - 2)
      guard allowance >= 256 else {
        omitted = true
        continue
      }
      let text = itemText(item)
      let excerpt = headAndTail(text, maximumBytes: allowance)
      omitted = omitted || excerpt != text
      body += "\n\n" + excerpt
    }
    for path in packet.changedFiles {
      let line = "\n历史改动文件（非实时 diff）：" + path
      guard body.utf8.count + line.utf8.count + footerReserve <= limit else {
        omitted = true
        continue
      }
      body += line
    }
    if omitted { warnings.append(omissionWarning) }
    let prompt = body + "\n\n" + warningText(warnings)
    guard prompt.utf8.count <= limit, !prompt.contains("\0") else {
      return blocked("交接正文超过预算或包含无效字符，已阻止发送。", warnings: warnings)
    }
    return Result(
      prompt: prompt, warnings: warnings, ready: true, estimatedTokens: prompt.utf8.count)
  }

  public static func headAndTail(_ text: String, maximumBytes: Int) -> String {
    guard text.utf8.count > maximumBytes else { return text }
    let marker = "\n[中段已节选；不是完整日志]\n"
    guard maximumBytes > marker.utf8.count else { return "" }
    let available = maximumBytes - marker.utf8.count
    let headBudget = available / 2
    var head = ""
    var tail: [Character] = []
    var used = 0
    for character in text {
      let value = String(character)
      guard used + value.utf8.count <= headBudget else { break }
      head.append(character)
      used += value.utf8.count
    }
    used = 0
    for character in text.reversed() {
      let value = String(character)
      guard used + value.utf8.count <= available - headBudget else { break }
      tail.append(character)
      used += value.utf8.count
    }
    return head + marker + String(tail.reversed())
  }

  private static func itemText(_ item: TaskHandoffItem) -> String {
    "[\(item.kind) | 来源 \(item.sourceTaskID) | \(item.id)]\n\(item.text)"
  }

  private static func warningText(_ warnings: [String]) -> String {
    "注意：\n" + warnings.map { "- " + $0 }.joined(separator: "\n")
  }

  private static func blocked(_ reason: String, warnings: [String]) -> Result {
    Result(prompt: "", warnings: warnings + [reason], ready: false, estimatedTokens: 0)
  }
}
