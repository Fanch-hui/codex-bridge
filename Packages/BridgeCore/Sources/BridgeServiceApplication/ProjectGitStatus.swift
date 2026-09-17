import BridgeDirectCommand
import BridgeMCP
import BridgeServiceCore
import Foundation

enum ProjectGitStatus {
  static func read(
    _ project: ServiceProjectRecord, deadline: ContinuousClock.Instant
  ) async -> String? {
    guard project.accessPolicy.read == .allowed else { return nil }
    let remaining = ContinuousClock.now.duration(to: deadline)
    guard remaining > .zero else { return "check_failed" }
    do {
      try project.root.validateCurrentIdentity()
      let result = try await DirectGitRunner().run(
        argv: [
          DirectGitRunner.gitPath, "--no-pager", "--no-optional-locks",
          "-c", "core.fsmonitor=false", "-c", "core.untrackedCache=false",
          "status", "--porcelain=v1", "-z", "--untracked-files=normal",
        ],
        workingDirectory: project.root.canonicalPath,
        timeout: min(remaining, .seconds(3)),
        environment: ["LANG": "C", "LC_ALL": "C", "GIT_TERMINAL_PROMPT": "0"]
      )
      try project.root.validateCurrentIdentity()
      if result.exitCode == 0 {
        if result.output.byteCount == 0 { return "clean" }
        return result.output.head.contains("\0") || result.output.tail.contains("\0")
          ? "dirty" : "check_failed"
      }
      let output = result.output.head
      return output.contains("fatal: not a git repository") ? "not_git" : "check_failed"
    } catch {
      return "check_failed"
    }
  }
}

extension BridgeServiceApplication {
  static func checkedProjectSummaries(
    _ projects: [ServiceProjectRecord], deadline: ContinuousClock.Instant
  ) async -> [MCPProjectSummary] {
    var summaries: [MCPProjectSummary] = []
    for start in stride(from: 0, to: projects.count, by: 4) {
      let batch = await withTaskGroup(of: (Int, MCPProjectSummary).self) { group in
        for index in start..<min(start + 4, projects.count) {
          let project = projects[index]
          group.addTask {
            let state = await ProjectGitStatus.read(project, deadline: deadline)
            return (index, Self.projectSummary(project, gitState: state))
          }
        }
        var results: [(Int, MCPProjectSummary)] = []
        for await result in group { results.append(result) }
        return results.sorted { $0.0 < $1.0 }.map(\.1)
      }
      summaries.append(contentsOf: batch)
    }
    return summaries
  }
}
