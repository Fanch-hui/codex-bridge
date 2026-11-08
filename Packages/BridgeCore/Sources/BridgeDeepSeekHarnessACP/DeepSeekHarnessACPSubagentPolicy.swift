import BridgeProcess
import Foundation

enum DeepSeekHarnessACPSubagentPolicy {
  private static let disabledIDs = [
    "tool-subagent", "tool-subagent-fork", "tool-subagent-control",
    "tool-agent-team", "tool-ralph", "tool-workflow",
  ]
  private static let disabledPackages: Set<String> = [
    "@deepseek-ai/dsh-tool-subagent", "@deepseek-ai/dsh-tool-subagent-control",
    "@deepseek-ai/dsh-experimental-tool-agent-team", "@deepseek-ai/dsh-tool-ralph",
    "@deepseek-ai/dsh-tool-workflow",
  ]
  private static let requiredIDs: Set<String> = ["tool-subagent", "tool-subagent-fork"]
  private static let environmentKeys: Set<String> = [
    "HOME", "PATH", "TMPDIR", "TEMP", "TMP", "USERPROFILE", "SystemRoot", "SYSTEMROOT",
    "WINDIR", "XDG_CONFIG_HOME", "XDG_CACHE_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME",
    "DSH_HOME", "DSH_SNAPSHOT_SESSIONS_ROOT", "DSH_WORKSPACE_ROOT", "DSH_PERMISSION_MODE",
    "ELECTRON_RUN_AS_NODE",
  ]

  static var patch: String {
    disabledIDs.map { "- id: \($0)\n  disabled: true\n" }.joined()
  }

  static func verify(_ launch: DeepSeekHarnessACPLaunchConfiguration) async throws -> Bool {
    try Task.checkCancellation()
    var argv = launch.process.argv
    guard let importIndex = argv.firstIndex(of: "--import"), importIndex + 1 < argv.count else {
      return false
    }
    argv.removeSubrange(importIndex...importIndex + 1)
    argv.append("--dump-config")
    let environment = launch.process.environment.filter { environmentKeys.contains($0.key) }
    let output = BoundedProcessOutputCollector(maximumBytes: 32 * 1_024)
    let process: ManagedStdioProcess
    do {
      process = try ManagedStdioProcess(
        argv: argv, workingDirectory: launch.process.workingDirectory, environment: environment,
        mergeStandardError: false, onStandardOutput: output.append)
    } catch {
      try Task.checkCancellation()
      return false
    }
    process.closeStdin()
    let result = await ManagedProcessRunner(defaultTimeout: .seconds(10)).monitor(process: process)
    try Task.checkCancellation()
    guard !result.timedOut, result.termination == .exited(0) else { return false }
    let captured = output.snapshot()
    return !captured.truncated && verifyDump(captured.tail)
  }

  static func verifyDump(_ value: String) -> Bool {
    var entries: [(id: String, name: String?, disabled: Bool)] = []
    for line in value.components(separatedBy: .newlines) {
      if line.hasPrefix("- id: ") {
        entries.append((scalar(line.dropFirst(6)), nil, false))
      } else if !entries.isEmpty, line.hasPrefix("  name: ") {
        entries[entries.count - 1].name = scalar(line.dropFirst(8))
      } else if !entries.isEmpty, line == "  disabled: true" {
        entries[entries.count - 1].disabled = true
      }
    }
    let ids = entries.map(\.id)
    guard Set(ids).count == ids.count, requiredIDs.isSubset(of: Set(ids)) else { return false }
    return entries.allSatisfy { entry in
      if disabledIDs.contains(entry.id) || entry.name.map(disabledPackages.contains) == true {
        return entry.disabled
      }
      return true
    }
  }

  private static func scalar(_ value: Substring) -> String {
    value.trimmingCharacters(in: CharacterSet(charactersIn: " '\""))
  }
}
