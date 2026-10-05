@testable import BridgeDirectCommand
import BridgeProjects
import Foundation
import Testing

@Suite("DirectCommandPolicy resolution matrix")
struct DirectCommandPolicyTests {

  // MARK: mode gating

  @Test("denied mode rejects everything up front")
  func deniedMode() throws {
    let policy = DirectCommandPolicy(builtInSafeRules: [])
    let project = try TestFixtures.makeProjectRecord(mode: .denied)
    let request = DirectCommandRequest(
      projectID: project.id, commandID: nil, argv: ["make", "build"])
    let resolution = policy.resolve(project: project, request: request)
    #expect(resolution == .denied(.commandModeDenied))
  }

  // MARK: argument sanity

  @Test("oversized argv and working directories are invalid")
  func invalidArguments() throws {
    let policy = DirectCommandPolicy(builtInSafeRules: [])
    let project = try TestFixtures.makeProjectRecord(mode: .full)
    let tooManyArguments = Array(repeating: "arg", count: 129)
    var resolution = policy.resolve(
      project: project,
      request: DirectCommandRequest(
        projectID: project.id, commandID: nil, argv: tooManyArguments))
    #expect(resolution == .denied(.invalidArguments))

    let longDirectory = String(repeating: "d", count: 1_025)
    resolution = policy.resolve(
      project: project,
      request: DirectCommandRequest(
        projectID: project.id, commandID: nil, argv: ["tool"],
        workingDirectory: longDirectory))
    #expect(resolution == .denied(.invalidArguments))

    resolution = policy.resolve(
      project: project,
      request: DirectCommandRequest(projectID: project.id, commandID: nil, argv: []))
    #expect(resolution == .denied(.invalidArguments))
  }

  // MARK: registered commands

  @Test("safe mode allows registered commands and keeps their argv")
  func registeredCommand() throws {
    let policy = DirectCommandPolicy(builtInSafeRules: [])
    let command = try TestFixtures.makeCommand(id: "cmd-1", executable: "make", arguments: ["build"])
    let project = try TestFixtures.makeProjectRecord(mode: .safe, commands: [command])
    let request = DirectCommandRequest(
      projectID: project.id, commandID: nil, argv: ["make", "build", "--fast"])
    let resolution = policy.resolve(project: project, request: request)
    #expect(resolution.allowed)
    #expect(resolution.argv == ["make", "build", "--fast"])
    #expect(resolution.requiresApproval == false)
    #expect(resolution.reason == nil)
  }

  @Test("argument prefixes must match the registered command")
  func registeredCommandPrefix() throws {
    let policy = DirectCommandPolicy(builtInSafeRules: [])
    let command = try TestFixtures.makeCommand(id: "cmd-1", executable: "make", arguments: ["build"])
    let project = try TestFixtures.makeProjectRecord(mode: .safe, commands: [command])
    let resolution = policy.resolve(
      project: project,
      request: DirectCommandRequest(
        projectID: project.id, commandID: nil, argv: ["make", "clean"]))
    #expect(resolution == .denied(.commandNotRegistered))
  }

  @Test("safe mode rejects unregistered commands without a project-local executable")
  func unregisteredRejected() throws {
    let policy = DirectCommandPolicy(builtInSafeRules: [])
    let project = try TestFixtures.makeProjectRecord(mode: .safe)
    let resolution = policy.resolve(
      project: project,
      request: DirectCommandRequest(
        projectID: project.id, commandID: nil, argv: ["definitely-not-a-tool-zzz", "run"]))
    #expect(resolution == .denied(.commandNotRegistered))
  }

  @Test("command IDs must exist in the workspace command list")
  func unknownCommandID() throws {
    let policy = DirectCommandPolicy(builtInSafeRules: [])
    let project = try TestFixtures.makeProjectRecord(mode: .safe)
    let resolution = policy.resolve(
      project: project,
      request: DirectCommandRequest(
        projectID: project.id, commandID: "missing", argv: ["make"]))
    #expect(resolution == .denied(.unknownCommand))
  }

  @Test("command IDs bind argv to the registered executable")
  func commandIDMismatch() throws {
    let policy = DirectCommandPolicy(builtInSafeRules: [])
    let command = try TestFixtures.makeCommand(id: "cmd-1", executable: "make", arguments: ["build"])
    let project = try TestFixtures.makeProjectRecord(mode: .safe, commands: [command])
    let resolution = policy.resolve(
      project: project,
      request: DirectCommandRequest(
        projectID: project.id, commandID: "cmd-1", argv: ["other-tool", "build"]))
    #expect(resolution == .denied(.invalidArguments))
  }

  @Test("empty argv with a command ID expands to the registered command")
  func commandIDExpandsArgv() throws {
    let policy = DirectCommandPolicy(builtInSafeRules: [])
    let command = try TestFixtures.makeCommand(id: "cmd-1", executable: "make", arguments: ["build"])
    let project = try TestFixtures.makeProjectRecord(mode: .safe, commands: [command])
    let resolution = policy.resolve(
      project: project,
      request: DirectCommandRequest(projectID: project.id, commandID: "cmd-1", argv: []))
    #expect(resolution.allowed)
    #expect(resolution.argv == ["make", "build"])
  }

  @Test("elevated-risk commands always require approval")
  func elevatedRiskRequiresApproval() throws {
    let policy = DirectCommandPolicy(builtInSafeRules: [])
    let command = try TestFixtures.makeCommand(
      id: "cmd-1", executable: "make", arguments: ["build"], risk: .elevated)
    let project = try TestFixtures.makeProjectRecord(mode: .safe, commands: [command])
    let resolution = policy.resolve(
      project: project,
      request: DirectCommandRequest(
        projectID: project.id, commandID: nil, argv: ["make", "build"]))
    #expect(resolution.allowed)
    #expect(resolution.requiresApproval)
  }

  @Test("network commands inherit the project access policy")
  func networkPolicy() throws {
    let policy = DirectCommandPolicy(builtInSafeRules: [])
    let command = try TestFixtures.makeCommand(
      id: "cmd-1", executable: "make", arguments: ["publish"], requiresNetwork: true)
    let denied = try TestFixtures.makeProjectRecord(mode: .safe, commands: [command])
    let resolution = policy.resolve(
      project: denied,
      request: DirectCommandRequest(
        projectID: denied.id, commandID: nil, argv: ["make", "publish"]))
    #expect(resolution == .denied(.networkNotAllowed))

    let approval = try TestFixtures.makeProjectRecord(
      mode: .safe,
      commands: [command],
      accessPolicy: ProjectAccessPolicy(
        read: .allowed, write: .allowed, network: .requiresLocalApproval))
    let approved = policy.resolve(
      project: approval,
      request: DirectCommandRequest(
        projectID: approval.id, commandID: nil, argv: ["make", "publish"]))
    #expect(approved.allowed)
    #expect(approved.requiresApproval)
    #expect(approved.requiresNetwork)
  }

  @Test("denied write policy blocks allowed commands")
  func writePolicy() throws {
    let policy = DirectCommandPolicy(builtInSafeRules: [])
    let command = try TestFixtures.makeCommand(id: "cmd-1", executable: "make", arguments: ["build"])
    let project = try TestFixtures.makeProjectRecord(
      mode: .safe,
      commands: [command],
      accessPolicy: ProjectAccessPolicy(read: .allowed, write: .denied, network: .denied))
    let resolution = policy.resolve(
      project: project,
      request: DirectCommandRequest(
        projectID: project.id, commandID: nil, argv: ["make", "build"]))
    #expect(resolution == .denied(.writeNotAllowed))
  }

  @Test("validated skill scripts are allowed with approval in safe mode")
  func skillScriptRequiresApproval() throws {
    let policy = DirectCommandPolicy(builtInSafeRules: [])
    let project = try TestFixtures.makeProjectRecord(mode: .safe)
    let resolution = policy.resolve(
      project: project,
      request: DirectCommandRequest(
        projectID: project.id, commandID: nil, argv: ["run-validated-skill"],
        isValidatedSkillScript: true))
    #expect(resolution.allowed)
    #expect(resolution.requiresApproval)
  }

  // MARK: blacklist normalization

  @Test("blacklist matches executables by basename")
  func blacklistBasename() throws {
    let policy = DirectCommandPolicy(builtInSafeRules: [])
    let rule = try TestFixtures.makeBlacklistRule(id: "blk-1", executable: "curl")
    let project = try TestFixtures.makeProjectRecord(mode: .full, blacklist: [rule])
    let resolution = policy.resolve(
      project: project,
      request: DirectCommandRequest(
        projectID: project.id, commandID: nil,
        argv: ["curl", "https://example.invalid"]))
    #expect(resolution == .denied(.blacklisted))
  }

  @Test("blacklist rules bind to their argument prefix")
  func blacklistArgumentPrefix() throws {
    let policy = DirectCommandPolicy(builtInSafeRules: [])
    let rule = try TestFixtures.makeBlacklistRule(
      id: "blk-1", executable: "git", arguments: ["push"])
    let project = try TestFixtures.makeProjectRecord(mode: .full, blacklist: [rule])
    let blocked = policy.resolve(
      project: project,
      request: DirectCommandRequest(
        projectID: project.id, commandID: nil, argv: ["git", "push", "origin"]))
    #expect(blocked == .denied(.blacklisted))
    let allowed = policy.resolve(
      project: project,
      request: DirectCommandRequest(
        projectID: project.id, commandID: nil, argv: ["git", "status"]))
    #expect(allowed.allowed)
  }

  @Test("blacklist patterns scan the whole argv")
  func blacklistPattern() throws {
    let policy = DirectCommandPolicy(builtInSafeRules: [])
    let rule = try TestFixtures.makeBlacklistRule(id: "blk-1", pattern: "example.invalid")
    let project = try TestFixtures.makeProjectRecord(mode: .full, blacklist: [rule])
    let resolution = policy.resolve(
      project: project,
      request: DirectCommandRequest(
        projectID: project.id, commandID: nil,
        argv: ["printer", "visit https://EXAMPLE.invalid/now"]))
    #expect(resolution == .denied(.blacklisted))
  }

  // MARK: case-insensitive executable matching (Windows)

  @Test("registered command matching is case-insensitive on Windows only")
  func executableCaseSensitivity() throws {
    let policy = DirectCommandPolicy(builtInSafeRules: [])
    let command = try TestFixtures.makeCommand(id: "cmd-1", executable: "make", arguments: ["build"])
    let project = try TestFixtures.makeProjectRecord(mode: .safe, commands: [command])
    let resolution = policy.resolve(
      project: project,
      request: DirectCommandRequest(
        projectID: project.id, commandID: nil, argv: ["MAKE", "build"]))
    #if os(Windows)
      #expect(resolution.allowed)
      #expect(resolution.argv == ["MAKE", "build"])
    #else
      #expect(resolution == .denied(.commandNotRegistered))
    #endif
  }

  // MARK: git built-in hardening (deterministic on POSIX)

  #if !os(Windows)
    @Test("git built-in invocations are allowed and hardened in safe mode")
    func gitBuiltInHardening() throws {
      let policy = DirectCommandPolicy(
        builtInSafeRules: [
          DirectCommandPolicy.DirectSafeCommandRule(executable: "git", argumentsPrefix: ["status"])
        ])
      let project = try TestFixtures.makeProjectRecord(mode: .safe)
      let resolution = policy.resolve(
        project: project,
        request: DirectCommandRequest(
          projectID: project.id, commandID: nil, argv: ["git", "status"]))
      #expect(resolution.allowed)
      #expect(
        resolution.argv
          == [
            "git", "--no-pager", "-c", "core.fsmonitor=false",
            "-c", "log.showSignature=false", "-c", "format.pretty=medium", "status",
          ])
    }

    @Test("git built-ins with unsafe options are rejected")
    func gitBuiltInUnsafeOptions() throws {
      let policy = DirectCommandPolicy(
        builtInSafeRules: [
          DirectCommandPolicy.DirectSafeCommandRule(executable: "git", argumentsPrefix: ["log"]),
          DirectCommandPolicy.DirectSafeCommandRule(
            executable: "git", argumentsPrefix: ["branch"]),
        ])
      let project = try TestFixtures.makeProjectRecord(mode: .safe)
      for argv in [["git", "log", "--exec=/bin/sh"], ["git", "log", "-C", "/etc"], ["git", "branch", "--list", "-x"]] {
        let resolution = policy.resolve(
          project: project,
          request: DirectCommandRequest(projectID: project.id, commandID: nil, argv: argv))
        #expect(resolution == .denied(.invalidArguments), "expected rejection for \(argv)")
      }
    }
  #endif

  @Test("git argument validator denies repository-pinning options")
  func gitArgumentValidatorDenials() {
    #expect(!DirectGitArgumentValidator.areArgumentsSafe(["status", "-C", "/elsewhere"]))
    #expect(!DirectGitArgumentValidator.areArgumentsSafe(["log", "--git-dir=/x"]))
    #expect(!DirectGitArgumentValidator.areArgumentsSafe(["show", "--output=x"]))
    #expect(!DirectGitArgumentValidator.areArgumentsSafe(["diff", "--textconv=x"]))
    #expect(!DirectGitArgumentValidator.areArgumentsSafe(["branch", "-c", "a=b"]))
    #expect(DirectGitArgumentValidator.areArgumentsSafe(["status"]))
    #expect(DirectGitArgumentValidator.areArgumentsSafe(["--version"]))
    #expect(DirectGitArgumentValidator.areArgumentsSafe(["branch", "--show-current"]))
    #expect(DirectGitArgumentValidator.areArgumentsSafe(["branch", "--list", "-v"]))
    #expect(DirectGitArgumentValidator.areArgumentsSafe(["log", "--pretty=oneline"]))
  }

  @Test("git execution arguments always pin pager and fsmonitor off")
  func gitExecutionArguments() {
    #expect(
      DirectGitArgumentValidator.executionArguments(["git", "diff", "HEAD"])
        == [
          "git", "--no-pager", "-c", "core.fsmonitor=false",
          "-c", "log.showSignature=false", "-c", "format.pretty=medium", "diff",
          "--no-ext-diff", "--no-textconv", "HEAD",
        ])
  }
}
