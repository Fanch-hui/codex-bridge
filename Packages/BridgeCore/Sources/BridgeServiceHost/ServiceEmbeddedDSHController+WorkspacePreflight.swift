import BridgeAgentCore
import BridgeCodexRPC
import BridgeFiles
import BridgeServiceCore
import Foundation

private enum WorkspacePreflightFailure: Error {
  case processNotStopped
}

extension ServiceEmbeddedDSHController {
  func externalWorkspaceIsReady(
    providerID: String, installationID: String, snapshot: AgentWorkspaceSnapshot
  ) async throws -> AgentWorkspaceIsolationReadiness {
    try snapshot.runtimeRoot.validateCurrentIdentity()
    let temporary = URL(fileURLWithPath: snapshot.runtimeRoot.canonicalPath, isDirectory: true)
      .appendingPathComponent("preflight-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let result = try await externalWorkspaceReadiness(
      providerID, installationID, snapshot, temporary.path)
    try snapshot.runtimeRoot.validateCurrentIdentity()
    try FileManager.default.removeItem(at: temporary)
    return result
  }

  func isolatedWorkspaceIsReady(_ snapshot: AgentWorkspaceSnapshot) async throws
    -> (ready: Bool, reason: String?)
  {
    guard CodexIsolatedLaunch.isAvailable else { return (false, "当前平台的进程隔离不可用。") }
    let status = try await application.serviceStatus(
      deadline: .now.advanced(by: .seconds(10)))
    guard let executable = status.codexResolvedExecutablePath else {
      return (false, "Codex 程序暂不可用。")
    }
    try snapshot.runtimeRoot.validateCurrentIdentity()
    let temporary = URL(fileURLWithPath: snapshot.runtimeRoot.canonicalPath, isDirectory: true)
      .appendingPathComponent("preflight-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let configuration: AppServerConfiguration
    do {
      configuration = try CodexIsolatedLaunch.prepare(
        configuration: .codex(configuredPath: executable),
        workspaceRoot: URL(fileURLWithPath: snapshot.workspaceRoot.canonicalPath),
        runtimeDirectory: temporary)
    } catch {
      try FileManager.default.removeItem(at: temporary)
      throw error
    }
    let client = CodexAppServerClient(
      configuration: configuration, defaultTimeoutNanoseconds: 10_000_000_000)
    do {
      try await client.start()
      _ = try await client.initialize(
        clientInfo: CodexClientInfo(name: "bridge-workspace-preflight", title: nil, version: "1"))
      guard try await isolatedMCPIsEmpty(client, threadID: nil) else {
        guard try await finishWorkspacePreflight(client, directory: temporary) else {
          throw WorkspacePreflightFailure.processNotStopped
        }
        return (false, "该连接启用了外部工具，使用共享目录执行。")
      }
      let thread = try await client.startThread(
        ThreadStartParams(
          cwd: snapshot.workspaceRoot.canonicalPath, sandbox: .dangerFullAccess,
          approvalPolicy: .never, approvalsReviewer: "user", ephemeral: true))
      let ready = try await isolatedMCPIsEmpty(client, threadID: thread.thread.id)
      let stopped = try await finishWorkspacePreflight(client, directory: temporary)
      guard stopped else { throw WorkspacePreflightFailure.processNotStopped }
      return (
        ready,
        ready ? "独立副本仅使用文件工具，构建与测试由合并验证执行。" : "该会话启用了外部工具，使用共享目录执行。"
      )
    } catch is CancellationError {
      guard try await finishWorkspacePreflight(client, directory: temporary) else {
        throw WorkspacePreflightFailure.processNotStopped
      }
      throw CancellationError()
    } catch let error as WorkspacePreflightFailure {
      throw error
    } catch {
      guard try await finishWorkspacePreflight(client, directory: temporary) else {
        throw WorkspacePreflightFailure.processNotStopped
      }
      return (false, "隔离执行的启动检查未通过。")
    }
  }

  private func finishWorkspacePreflight(_ client: CodexAppServerClient, directory: URL)
    async throws -> Bool
  {
    await client.stop()
    guard await client.confirmedStopped() else { return false }
    if FileManager.default.fileExists(atPath: directory.path) {
      try FileManager.default.removeItem(at: directory)
    }
    return true
  }

  private func isolatedMCPIsEmpty(_ client: CodexAppServerClient, threadID: String?)
    async throws -> Bool
  {
    var params: [String: JSONValue] = ["limit": .integer(1)]
    if let threadID { params["threadId"] = .string(threadID) }
    let response = try await client.request(
      method: "mcpServerStatus/list", params: .object(params))
    guard let object = response.objectValue, case .array(let servers)? = object["data"] else {
      return false
    }
    return servers.isEmpty && (object["nextCursor"] == nil || object["nextCursor"] == .null)
  }
}
