import BridgeACP
import BridgeAgentCore
import BridgeProcess
import Foundation

extension ClaudeSDKProvider: AgentWorkspaceIsolationProviding {
  public func isolatedWorkspaceReadiness(
    installation: AgentInstallation, workspaceRoot: String, runtimeDirectory: String
  ) async throws -> AgentWorkspaceIsolationReadiness {
    guard WorkspaceProcessIsolation.isAvailable else {
      return .init(ready: false, reason: "当前平台的进程隔离不可用。")
    }
    do {
      guard try await configuration.configuredMCPServerCount(installation) == 0 else {
        return .init(ready: false, reason: "该连接启用了外部工具，使用共享目录执行。")
      }
      let identity = try await authenticationIdentity(
        installation: installation, projectRoot: workspaceRoot)
      let profile = try await ClaudeRuntimeProfile.make(
        installation: installation, configuration: configuration)
      let isolation = try AgentWorkspaceIsolation(runtimeDirectory: runtimeDirectory)
      let client = try profile.client(
        cwd: workspaceRoot, isolation: isolation, factory: configuration.transportFactory)
      let metadata: ACPJSONValue
      do {
        metadata = try await client.request(
          "claude/probe",
          params: profile.parameters(
            cwd: workspaceRoot, sessionID: UUID().uuidString.lowercased(),
            request: nil, resources: .init(), isolated: true))
      } catch {
        guard await client.shutdown() else { throw ClaudeProcessStillRunning() }
        throw error
      }
      guard await client.shutdown() else { throw ClaudeProcessStillRunning() }
      try Self.validate(metadata)
      try Self.requireAuthenticated(metadata)
      guard metadata["identityScopeVerified"]?.boolValue == true,
        metadata["identityScopeDigest"]?.stringValue == identity
      else {
        return .init(ready: false, reason: "隔离环境无法使用当前 Claude Code 登录。")
      }
      return .init(
        ready: true,
        reason: "独立执行使用受控文件和网络工具；构建与测试由合并候选验证。")
    } catch is CancellationError {
      throw CancellationError()
    } catch is ClaudeProcessStillRunning {
      throw AgentRuntimeError.processUnavailable
    } catch {
      return .init(ready: false, reason: "Claude Code 的隔离启动检查未通过。")
    }
  }

  func authenticationIdentity(installation: AgentInstallation, projectRoot: String) async throws
    -> String
  {
    let metadata = try await inspect(
      installation: installation, method: "claude/auth", projectRoot: projectRoot)
    try Self.validate(metadata)
    try Self.requireAuthenticated(metadata)
    guard metadata["identityScopeVerified"]?.boolValue == true,
      let identity = metadata["identityScopeDigest"]?.stringValue,
      identity.utf8.count == 64,
      identity.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
    else { throw AgentRuntimeError.sessionMismatch }
    return identity
  }
}
