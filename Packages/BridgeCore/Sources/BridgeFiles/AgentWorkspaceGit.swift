import BridgeAgentCore
import BridgeGit
import Foundation

extension AgentWorkspaceStore {
  func initializePrivateGit(at workspace: URL, staging: URL) async throws {
    let templates = staging.appendingPathComponent("git-template", isDirectory: true)
    try FileManager.default.createDirectory(at: templates, withIntermediateDirectories: false)
    let executable: String
    #if os(Windows)
      guard let resolved = AgentExecutableResolver().resolve("git") else {
        throw AgentWorkspaceError.gitUnavailable
      }
      executable = resolved
    #else
      executable = "/usr/bin/git"
    #endif
    let workingDirectory = try OpenedWorkingDirectory(canonicalURL: workspace)
    let common = [
      "-c", "core.hooksPath=\(templates.path)",
      "-c", "commit.gpgsign=false", "-c", "core.fsmonitor=false",
      "-c", "user.name=Codex Bridge", "-c", "user.email=codex-bridge@localhost",
    ]
    for command in [
      ["init", "--quiet", "--template=\(templates.path)"],
      ["add", "--force", "--all", "--", "."],
      ["commit", "--quiet", "--allow-empty", "--no-verify", "-m", "Workspace snapshot"],
    ] {
      let result = try await BoundedProcessRunner().run(
        BoundedProcessConfiguration(
          executableURL: URL(fileURLWithPath: executable), arguments: common + command,
          workingDirectory: workingDirectory, environment: Self.gitEnvironment(),
          timeout: .seconds(120), terminationGracePeriod: .seconds(1),
          maximumStandardOutputBytes: 64 * 1_024, maximumStandardErrorBytes: 64 * 1_024))
      guard result.termination == .exited(0) else { throw AgentWorkspaceError.gitUnavailable }
    }
  }

  private static func gitEnvironment() -> [String] {
    var environment = [
      "LANG=C", "LC_ALL=C", "GIT_CONFIG_NOSYSTEM=1", "GIT_ATTR_NOSYSTEM=1",
      "GIT_TERMINAL_PROMPT=0", "GIT_PAGER=cat", "PAGER=cat",
    ]
    #if os(Windows)
      environment.append("GIT_CONFIG_GLOBAL=NUL")
      let source = ProcessInfo.processInfo.environment
      let keys = ["SystemRoot", "WINDIR", "SystemDrive", "TEMP", "TMP", "PATH", "PATHEXT"]
      environment += keys.compactMap { key in
        guard
          let name = source.keys.first(where: { $0.caseInsensitiveCompare(key) == .orderedSame }),
          let value = source[name]
        else { return nil }
        return "\(key)=\(value)"
      }
    #else
      environment += ["PATH=/usr/bin:/bin", "GIT_CONFIG_GLOBAL=/dev/null"]
    #endif
    return environment
  }
}
