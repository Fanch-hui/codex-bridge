import BridgeIPC
import BridgeMCP
import Foundation

public enum TaskHandoffSummary {
  public static func prompt(
    task: MCPServiceTaskSnapshot, history: [MCPServiceTaskSnapshot], gitState: String?
  ) -> String {
    let turns = history.isEmpty ? [task] : history
    var parts = [
      "接手以下项目任务，先核对当前工作区，再继续未完成事项。", "来源任务：\(task.taskID)", "来源 Agent：\(task.providerDisplayName)",
    ]
    if let first = turns.first?.prompt, !first.isEmpty {
      parts.append("起始要求：\n" + bounded(first, bytes: 4096))
    }
    for turn in turns.dropFirst().suffix(6) {
      if let prompt = turn.prompt, !prompt.isEmpty {
        parts.append("补充要求（\(turn.taskID)）：\n" + bounded(prompt, bytes: 1024))
      }
    }
    if turns.count > 7 { parts.append("要求摘自起始轮与最近六轮；较早补充可在来源会话中查看。") }
    if let result = task.resultSummary, !result.isEmpty {
      parts.append("已有结果：\n" + bounded(result, bytes: 8192))
    }
    if let step = task.currentStep { parts.append("最后记录步骤：\n" + bounded(step, bytes: 2048)) }
    parts.append("任务状态：\(task.status)")
    if let gitState { parts.append("最近 Git 状态：\(gitState)") }
    let changed = Array(Set(turns.flatMap(\.changedFiles))).sorted()
    if !changed.isEmpty { parts.append("记录的改动文件：\n" + changed.prefix(100).joined(separator: "\n")) }
    let commands = turns.flatMap(\.recentEvents).filter { $0.kind == "execution.command_completed" }
    if !commands.isEmpty {
      parts.append("已记录命令结果：\n" + commands.suffix(20).map(\.summary).joined(separator: "\n"))
    }
    if let code = task.failureCode { parts.append("失败记录：\(code)") }
    return bounded(parts.joined(separator: "\n\n"), bytes: 30 * 1024)
  }

  public static func providers(
    excluding providerID: String, installations: [IPCAgentInstallationSummary]
  ) -> [(id: String, name: String)] {
    var result: [(id: String, name: String)] = providerID == "codex" ? [] : [("codex", "Codex")]
    for installation in installations
    where installation.isEnabled && installation.availability == "available"
      && installation.providerID != providerID
    {
      guard !result.contains(where: { $0.id == installation.providerID }) else { continue }
      let names = [
        "opencode": "OpenCode", "deepseek-harness": "DeepSeek Harness",
        "antigravity": "Antigravity",
      ]
      result.append(
        (installation.providerID, names[installation.providerID] ?? installation.displayName))
    }
    return result
  }

  private static func bounded(_ text: String, bytes: Int) -> String {
    guard text.utf8.count > bytes else { return text }
    var end = text.utf8.index(text.utf8.startIndex, offsetBy: bytes)
    while String.Index(end, within: text) == nil { end = text.utf8.index(before: end) }
    let prefix = String(text[..<String.Index(end, within: text)!])
    return prefix + "\n（摘要节选；完整记录可按来源任务查看）"
  }
}
