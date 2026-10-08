import BridgeDirectCommand
import BridgeMCP
import BridgeSecurity
import BridgeServiceCore
import Foundation

public struct WorkbenchGitEntry: Equatable, Sendable {
  public let relativePath: String
  public let originalPath: String?
  public let indexStatus: String
  public let worktreeStatus: String
}

public struct WorkbenchGitStatus: Equatable, Sendable {
  public let state: String
  public let entries: [WorkbenchGitEntry]
  public let truncated: Bool
}

public struct WorkbenchGitDiff: Equatable, Sendable {
  public let relativePath: String
  public let text: String
  public let truncated: Bool
}

enum WorkbenchGitInspection {
  static let maximumBytes = 256 * 1_024

  static func status(
    project: ServiceProjectRecord, limit: Int, deadline: ContinuousClock.Instant
  ) async throws -> WorkbenchGitStatus {
    guard limit > 0, limit <= 500 else { throw BridgeMCPQueryError.contractRejected }
    let result = try await run(
      [
        "status", "--porcelain=v1", "-z", "--untracked-files=all", "--no-renames",
        "--ignore-submodules=all",
      ], project: project, deadline: deadline)
    guard result.exitCode == 0 else {
      return WorkbenchGitStatus(
        state: result.output.head.contains("fatal: not a git repository")
          ? "not_git" : "check_failed",
        entries: [], truncated: false)
    }
    guard let data = result.completeOutput else {
      return WorkbenchGitStatus(state: "dirty", entries: [], truncated: true)
    }
    let records = data.split(separator: 0)
    var entries: [WorkbenchGitEntry] = []
    for record in records {
      guard record.count >= 4, let value = String(data: record, encoding: .utf8) else {
        return WorkbenchGitStatus(state: "check_failed", entries: [], truncated: false)
      }
      let path = String(value.dropFirst(3))
      guard safePath(path, project: project) else { continue }
      entries.append(
        WorkbenchGitEntry(
          relativePath: path, originalPath: nil,
          indexStatus: String(value.prefix(1)), worktreeStatus: String(value.dropFirst().prefix(1)))
      )
    }
    return WorkbenchGitStatus(
      state: records.isEmpty ? "clean" : "dirty", entries: Array(entries.prefix(limit)),
      truncated: entries.count > limit)
  }

  static func diff(
    project: ServiceProjectRecord, path: String, deadline: ContinuousClock.Instant
  ) async throws -> WorkbenchGitDiff {
    guard safePath(path, project: project) else { throw BridgeMCPQueryError.pathForbidden }
    let status = try await run(
      [
        "status", "--porcelain=v1", "-z", "--untracked-files=all", "--no-renames",
        "--ignore-submodules=all", "--", ":(literal)" + path,
      ],
      project: project, deadline: deadline)
    guard status.exitCode == 0, let records = status.completeOutput else {
      throw BridgeMCPQueryError.unavailable
    }
    if records.starts(with: Data("?? ".utf8)) {
      let text = try SecureFileReader(maximumBytes: maximumBytes, maximumLines: 10_000).read(
        SecureRelativePath(path), through: WorkbenchProjectAccess.resolver(for: project))
      var lines = text.text.split(separator: "\n", omittingEmptySubsequences: false).map(
        String.init)
      if text.text.hasSuffix("\n") { lines.removeLast() }
      if text.text.isEmpty { lines = [] }
      let patch =
        "--- /dev/null\n+++ " + path + "\n@@ -0,0 +1,\(lines.count) @@\n"
        + lines.map { "+" + $0 }.joined(separator: "\n")
      return WorkbenchGitDiff(
        relativePath: path,
        text: OutboundContentSecurity.redacted(patch, maximumUTF8Bytes: maximumBytes),
        truncated: text.truncated || patch.utf8.count > maximumBytes)
    }
    let flags = [
      "diff", "--no-ext-diff", "--no-textconv", "--no-renames",
      "--ignore-submodules=all", "--no-color",
    ]
    // Separate index and worktree patches preserve staged changes that were later reverted locally.
    let staged = try await run(
      flags + ["--cached", "--", ":(literal)" + path],
      project: project, deadline: deadline)
    let working = try await run(
      flags + ["--", ":(literal)" + path],
      project: project, deadline: deadline)
    guard staged.exitCode == 0, working.exitCode == 0 else { throw BridgeMCPQueryError.unavailable }
    let stagedText = text(staged)
    let workingText = text(working)
    let combined =
      (stagedText.isEmpty ? "" : "已暂存\n" + stagedText)
      + (workingText.isEmpty ? "" : "工作区\n" + workingText)
    return WorkbenchGitDiff(
      relativePath: path,
      text: OutboundContentSecurity.redacted(combined, maximumUTF8Bytes: maximumBytes),
      truncated: staged.completeOutput == nil || working.completeOutput == nil
        || combined.utf8.count > maximumBytes)
  }

  private static func text(_ result: DirectGitResult) -> String {
    result.completeOutput.flatMap { String(data: $0, encoding: .utf8) } ?? result.output.head
  }

  private static func run(
    _ arguments: [String], project: ServiceProjectRecord, deadline: ContinuousClock.Instant
  ) async throws -> DirectGitResult {
    try project.root.validateCurrentIdentity()
    let remaining = ContinuousClock.now.duration(to: deadline)
    guard remaining > .zero else { throw BridgeMCPQueryError.timeout }
    let result = try await DirectGitRunner().run(
      argv: [
        DirectGitRunner.gitPath, "--no-pager", "--no-optional-locks",
        "-c", "core.fsmonitor=false", "-c", "core.untrackedCache=false",
      ] + arguments,
      workingDirectory: project.root.canonicalPath, timeout: min(remaining, .seconds(5)),
      environment: ["LANG": "C", "LC_ALL": "C"],
      maximumOutputBytes: maximumBytes, restrictedEnvironment: true)
    try project.root.validateCurrentIdentity()
    return result
  }

  private static func safePath(_ value: String, project: ServiceProjectRecord) -> Bool {
    guard let path = try? SecureRelativePath(value),
      !path.components.contains(where: { $0.lowercased() == ".git" }),
      SensitivePathPolicy().allows(path)
    else { return false }
    guard let resolver = try? WorkbenchProjectAccess.resolver(for: project) else { return false }
    let target = URL(fileURLWithPath: project.root.canonicalPath).appending(path: path.value)
    if FileManager.default.fileExists(atPath: target.path) {
      return (try? resolver.resolve(path)) != nil
    }
    // Deleted files still have a pathspec; validate their nearest surviving parent.
    var parents = path.components.dropLast()
    while !parents.isEmpty {
      let relative = parents.joined(separator: "/")
      let candidate = URL(fileURLWithPath: project.root.canonicalPath).appending(path: relative)
      if FileManager.default.fileExists(atPath: candidate.path) {
        return (try? resolver.resolve(SecureRelativePath(relative))) != nil
      }
      parents = parents.dropLast()
    }
    return true
  }
}

extension BridgeServiceApplication {
  public func serviceWorkbenchGitStatus(
    projectID: String, limit: Int, deadline: ContinuousClock.Instant
  ) async throws -> WorkbenchGitStatus {
    try await WorkbenchGitInspection.status(
      project: readableProject(projectID), limit: limit, deadline: deadline)
  }

  public func serviceWorkbenchGitDiff(
    projectID: String, relativePath: String, deadline: ContinuousClock.Instant
  ) async throws -> WorkbenchGitDiff {
    try await WorkbenchGitInspection.diff(
      project: readableProject(projectID), path: relativePath, deadline: deadline)
  }
}
