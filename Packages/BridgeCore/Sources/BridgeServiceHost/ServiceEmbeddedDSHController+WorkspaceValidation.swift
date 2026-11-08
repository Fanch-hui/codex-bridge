import BridgeDomain
import BridgeFiles
import BridgeProcess
import BridgeSecurity
import BridgeServiceCore
import Foundation

let workspaceValidationExecution = AsyncMutex()

struct WorkbenchValidationFailure: Error, CustomStringConvertible, Sendable {
  let description: String
}

extension ServiceEmbeddedDSHController {
  func recoverWorkspaceValidationProcesses() async throws -> ManagedProcessOwnershipScope {
    let scope = try ManagedProcessOwnershipScope(
      directory: dataRoot.appendingPathComponent("WorkspaceValidationProcesses", isDirectory: true),
      ownerID: "candidate-validation")
    guard await Task.detached(operation: { scope.recover() }).value else {
      throw WorkbenchValidationFailure(description: "无法确认上一次验证进程已结束。")
    }
    return scope
  }

  func validateWorkspaceCandidate(
    _ candidate: AgentWorkspaceMergeCandidate, projectID: ProjectID,
    configuration: WorkbenchValidationConfiguration, scope: ManagedProcessOwnershipScope
  ) async throws {
    guard WorkspaceProcessIsolation.isAvailable,
      let snapshot = try await workspaces.snapshot(id: candidate.workspaceID)
    else { throw WorkbenchValidationFailure(description: "当前平台无法隔离验证进程。") }
    try snapshot.runtimeRoot.validateCurrentIdentity()
    let runtime = URL(fileURLWithPath: snapshot.runtimeRoot.canonicalPath, isDirectory: true)
      .appendingPathComponent("validation-" + candidate.id, isDirectory: true)
    try FileManager.default.createDirectory(
      at: runtime, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    var safeToRemove = true
    do {
      for command in configuration.commands {
        try Task.checkCancellation()
        let argv = try await application.prepareWorkspaceValidationCommand(
          projectID: projectID, executable: command.executable, arguments: command.arguments)
        let environment = [
          "PATH": URL(fileURLWithPath: argv[0]).deletingLastPathComponent().path
            + ":/usr/bin:/bin:/usr/sbin:/sbin",
          "LANG": "C", "LC_ALL": "C",
        ]
        let isolated = try WorkspaceProcessIsolation.prepare(
          executableURL: URL(fileURLWithPath: argv[0]), arguments: Array(argv.dropFirst()),
          environment: environment,
          workspaceRoot: URL(fileURLWithPath: candidate.root.canonicalPath),
          runtimeDirectory: runtime)
        let childEnvironment = isolated.environment
        let stdout = BoundedProcessOutputCollector(maximumBytes: 64 * 1_024)
        let stderr = BoundedProcessOutputCollector(maximumBytes: 64 * 1_024)
        let process = try ManagedProcessOwnership.$current.withValue(scope) {
          try ManagedStdioProcess(
            argv: [isolated.executableURL.path] + isolated.arguments,
            workingDirectory: candidate.root.canonicalPath, environment: childEnvironment,
            mergeStandardError: false, onStandardOutput: { stdout.append($0) },
            onStandardError: { stderr.append($0) })
        }
        let termination: ManagedProcessTermination
        do {
          termination = try await waitForWorkspaceValidation(
            process, timeoutSeconds: configuration.timeoutSeconds)
        } catch {
          safeToRemove = process.isProcessTreeStopped()
          process.close()
          throw error
        }
        process.drainRemainingOutput(timeout: .milliseconds(200))
        process.close()
        guard termination == .exited(0) else {
          let errorOutput = stderr.snapshot().tail
          let output = errorOutput.isEmpty ? stdout.snapshot().tail : errorOutput
          let detail = OutboundContentSecurity.redactedSecrets(output, maximumUTF8Bytes: 2_048)
          throw WorkbenchValidationFailure(
            description: "验证命令 \(command.executable) 失败：\(detail)")
        }
      }
      try FileManager.default.removeItem(at: runtime)
    } catch {
      if safeToRemove, FileManager.default.fileExists(atPath: runtime.path) {
        try FileManager.default.removeItem(at: runtime)
      }
      throw error
    }
  }

  private func waitForWorkspaceValidation(
    _ process: ManagedStdioProcess, timeoutSeconds: Int
  ) async throws -> ManagedProcessTermination {
    let deadline = ContinuousClock.now.advanced(by: .seconds(timeoutSeconds))
    while true {
      if let termination = process.reapIfExited(gracePeriod: .zero), process.isProcessTreeStopped()
      {
        return termination
      }
      if Task.isCancelled || ContinuousClock.now >= deadline {
        let stopped = await Task.detached {
          process.terminateProcessTreeAndWait()
        }.value
        guard stopped else {
          throw WorkbenchValidationFailure(description: "验证进程尚未确认退出，候选副本已保留。")
        }
        if Task.isCancelled { throw CancellationError() }
        throw WorkbenchValidationFailure(description: "验证命令超时。")
      }
      try? await Task.sleep(for: .milliseconds(30))
    }
  }
}
