import BridgeAgentCore
import BridgeGit
import BridgeProjects
import BridgeSecurity
import Foundation

public struct ProjectGitInspector: Sendable {
  public init() {}

  public func changes(root: RegisteredRoot) async throws -> ProjectChangesResult {
    try root.validateCurrentIdentity()
    let workingDirectory = try OpenedWorkingDirectory(
      canonicalURL: URL(fileURLWithPath: root.canonicalPath, isDirectory: true))
    let git = try Self.gitExecutable()

    let status = try await runGit(
      git: git,
      workingDirectory: workingDirectory,
      arguments: [
        "status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignore-submodules=all", "--",
      ]
    )
    if isGitRepositoryFailure(status) {
      return ProjectChangesResult(
        changedFiles: [],
        diff: "",
        additions: 0,
        deletions: 0,
        truncated: false,
        notGitRepository: true
      )
    }
    try requireSuccess(status)

    async let diffTask = runGit(
      git: git,
      workingDirectory: workingDirectory,
      arguments: ["diff", "--no-ext-diff", "--no-textconv", "--no-color", "--"]
    )
    async let cachedTask = runGit(
      git: git,
      workingDirectory: workingDirectory,
      arguments: ["diff", "--cached", "--no-ext-diff", "--no-textconv", "--no-color", "--"]
    )
    let (diff, cached) = try await (diffTask, cachedTask)
    try requireSuccess(diff)
    try requireSuccess(cached)
    let changedFiles = try parseStatus(status)
    let combined = combine(diff.standardOutput, cached.standardOutput)
    let stats = diffStatistics(combined)
    let output = boundedOutput(combined)
    return ProjectChangesResult(
      changedFiles: changedFiles,
      diff: output.text,
      additions: stats.additions,
      deletions: stats.deletions,
      truncated: output.truncated,
      notGitRepository: false
    )
  }

  private func isGitRepositoryFailure(_ result: BoundedProcessResult) -> Bool {
    guard case .exited(128) = result.termination else { return false }
    return String(decoding: result.standardError, as: UTF8.self)
      .lowercased()
      .contains("not a git repository")
  }

  private func requireSuccess(_ result: BoundedProcessResult) throws {
    if case .outputLimit = result.termination {
      throw ProjectGitInspectorError.commandOutputLimitExceeded
    }
    guard case .exited(let code) = result.termination, code == 0 else {
      throw ProjectGitInspectorError.commandFailed
    }
    guard !result.standardOutputTruncated, !result.standardErrorTruncated else {
      throw ProjectGitInspectorError.commandOutputLimitExceeded
    }
  }

  private func runGit(
    git: String,
    workingDirectory: OpenedWorkingDirectory,
    arguments: [String]
  ) async throws -> BoundedProcessResult {
    try workingDirectory.validatePathIdentity()
    let runner = BoundedProcessRunner()
    return try await runner.run(
      BoundedProcessConfiguration(
        executableURL: URL(fileURLWithPath: git),
        arguments: Self.globalGitArguments + arguments,
        workingDirectory: workingDirectory,
        environment: Self.gitEnvironment(),
        timeout: .seconds(10),
        terminationGracePeriod: .seconds(1),
        maximumStandardOutputBytes: 200 * 1_024,
        maximumStandardErrorBytes: 64 * 1_024
      )
    )
  }

  private static func gitExecutable() throws -> String {
    #if os(Windows)
      guard let path = AgentExecutableResolver().resolve("git") else {
        throw BoundedProcessError.launchFailed
      }
      return path
    #else
      return "/usr/bin/git"
    #endif
  }

  private static let globalGitArguments = [
    "--no-pager",
    "--no-optional-locks",
    "-c", "core.quotepath=false",
    "-c", "color.ui=false",
    "-c", "core.fsmonitor=false",
    "-c", "core.untrackedCache=false",
    "-c", "submodule.recurse=false",
  ]

  private static func gitEnvironment() -> [String] {
    #if os(Windows)
      let source = ProcessInfo.processInfo.environment
      let keys = [
        "SystemRoot", "WINDIR", "SystemDrive", "TEMP", "TMP", "USERPROFILE", "HOME",
        "LOCALAPPDATA", "APPDATA", "ProgramFiles", "ProgramFiles(x86)", "ProgramW6432",
        "PATH", "PATHEXT", "COMSPEC",
      ]
      return [
        "LANG=C",
        "LC_ALL=C",
        "GIT_CONFIG_NOSYSTEM=1",
        "GIT_CONFIG_GLOBAL=NUL",
        "GIT_ATTR_NOSYSTEM=1",
        "GIT_OPTIONAL_LOCKS=0",
        "GIT_TERMINAL_PROMPT=0",
        "GIT_PAGER=cat",
        "PAGER=cat",
      ]
        + keys.compactMap { key in
          guard
            let sourceKey = source.keys.first(where: {
              $0.caseInsensitiveCompare(key) == .orderedSame
            })
          else { return nil }
          return "\(key)=\(source[sourceKey] ?? "")"
        }
    #else
      return [
        "PATH=/usr/bin:/bin",
        "LANG=C",
        "LC_ALL=C",
        "GIT_CONFIG_NOSYSTEM=1",
        "GIT_CONFIG_GLOBAL=/dev/null",
        "GIT_ATTR_NOSYSTEM=1",
        "GIT_OPTIONAL_LOCKS=0",
        "GIT_TERMINAL_PROMPT=0",
        "GIT_PAGER=cat",
        "PAGER=cat",
      ]
    #endif
  }

  private func parseStatus(_ result: BoundedProcessResult) throws -> [String] {
    try requireSuccess(result)
    let records = Array(result.standardOutput)
      .split(separator: 0, omittingEmptySubsequences: true)
      .map(Array.init)
    var paths: [String] = []
    var index = 0
    while index < records.count {
      let record = records[index]
      guard record.count >= 4, record[2] == UInt8(ascii: " ") else {
        throw ProjectGitInspectorError.malformedStatus
      }
      appendPath(record.dropFirst(3), to: &paths)
      if record[0] == UInt8(ascii: "R") || record[0] == UInt8(ascii: "C") {
        index += 1
        guard index < records.count, !records[index].isEmpty else {
          throw ProjectGitInspectorError.malformedStatus
        }
        appendPath(records[index], to: &paths)
      }
      index += 1
    }
    return paths
  }

  private func appendPath<S: Collection>(
    _ bytes: S,
    to paths: inout [String]
  ) where S.Element == UInt8 {
    let decoded = String(decoding: bytes, as: UTF8.self)
    #if os(Windows)
      let path = decoded.replacingOccurrences(of: "\\", with: "/")
    #else
      let path = decoded
    #endif
    guard !path.isEmpty else { return }
    paths.append(path)
  }

  private func combine(_ a: Data, _ b: Data) -> Data {
    guard !b.isEmpty else { return a }
    guard !a.isEmpty else { return b }
    var combined = a
    combined.append(Data("\n".utf8))
    combined.append(b)
    return combined
  }

  private func diffStatistics(_ data: Data) -> (additions: Int, deletions: Int) {
    let text = String(decoding: data, as: UTF8.self)
    var additions = 0
    var deletions = 0
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
      if line.hasPrefix("+") && !line.hasPrefix("+++") {
        additions += 1
      } else if line.hasPrefix("-") && !line.hasPrefix("---") {
        deletions += 1
      }
    }
    return (additions, deletions)
  }

  private func boundedOutput(_ data: Data) -> (text: String, truncated: Bool) {
    let maximumBytes = 200 * 1_024
    let truncated = data.count > maximumBytes
    let bounded = data.prefix(maximumBytes)
    guard let text = String(data: bounded, encoding: .utf8) else {
      return (String(decoding: bounded, as: UTF8.self), truncated)
    }
    return (text, truncated)
  }
}

private enum ProjectGitInspectorError: Error, Equatable, Sendable {
  case commandFailed
  case commandOutputLimitExceeded
  case malformedStatus
}
