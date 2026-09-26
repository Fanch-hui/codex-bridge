import BridgeProcess
import Foundation

struct PiVersionProbe {
  static func read(_ launch: PiRPCLaunch) async throws -> String {
    guard !launch.executableArgv.isEmpty else { throw PiRPCError.incompatibleRuntime }
    let output = BoundedProcessOutputCollector(maximumBytes: 4 * 1_024)
    let process = try ManagedStdioProcess(
      argv: launch.executableArgv + ["--version"], workingDirectory: launch.workingDirectory,
      environment: launch.environment, mergeStandardError: false,
      onStandardOutput: { output.append($0) })
    process.closeStdin()
    let result = await ManagedProcessRunner(defaultTimeout: .seconds(10)).monitor(process: process)
    let captured = output.snapshot()
    guard result.termination == .exited(0), !result.timedOut, !captured.truncated else {
      throw PiRPCError.incompatibleRuntime
    }
    let text = captured.head.trimmingCharacters(in: .whitespacesAndNewlines)
    let pattern = #"^(?:pi\s+)?v?([0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?)$"#
    let expression = try NSRegularExpression(pattern: pattern, options: .caseInsensitive)
    guard let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
      let range = Range(match.range(at: 1), in: text)
    else { throw PiRPCError.incompatibleRuntime }
    return String(text[range])
  }
}
