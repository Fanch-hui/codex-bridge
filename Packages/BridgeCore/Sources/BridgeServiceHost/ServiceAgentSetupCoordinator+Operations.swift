import BridgeAgentCore
import BridgeIPC
import Foundation

extension ServiceAgentSetupCoordinator {
  func prepare(_ id: String) async {
    defer { workers.removeValue(forKey: id) }
    do {
      guard let operation = operations[id] else { return }
      let request = operation.request
      let candidates = try await dependencies.candidates(request)
      try Task.checkCancellation()
      if candidates.count > 1, request.installationID == nil {
        operations[id]?.snapshot.candidates = candidates
        update(
          id, state: "needs_user_action", message: "发现多个安装，请选择本次使用的安装。",
          userAction: "select_installation")
        return
      }
      let existing =
        request.installationID.flatMap { selected in
          candidates.first(where: { $0.installationID == selected })?.executablePath
        } ?? candidates.first?.executablePath
      update(id, state: "installing", message: existing == nil ? "正在准备安装…" : "正在检查运行依赖…")
      let runtime = try await installer.prepare(
        providerID: AgentProviderID(rawValue: request.providerID),
        distribution: request.qoderDistribution.flatMap(QoderDistribution.init(rawValue:)),
        root: request.installDirectory.map { URL(fileURLWithPath: $0, isDirectory: true) }
          ?? defaultRoot,
        existingExecutable: existing,
        report: { message in await self.update(id, message: message) })
      try Task.checkCancellation()
      guard var current = operations[id], current.snapshot.isRunning else { return }
      current.runtime = runtime
      current.snapshot.executablePath = runtime.executablePath
      current.snapshot.installationDirectory = runtime.installationDirectory
      current.snapshot.version = runtime.version
      current.snapshot.loginCommand = try dependencies.login(request, runtime)
      operations[id] = current
      update(id, state: "configuring", message: "正在准备 Agent 配置…")
      try await dependencies.configure(request, runtime)
      try Task.checkCancellation()
      if request.providerID == "antigravity" {
        update(
          id, state: "needs_user_action",
          message: "运行时已准备。连接 AGY 需要明确同意全局工具策略，然后验证登录状态。",
          userAction: "permission")
      } else {
        await verify(id, input: nil)
      }
    } catch is CancellationError {
      update(id, state: "cancelled", message: "配置已取消。")
    } catch {
      update(id, state: "failed", message: error.localizedDescription)
    }
  }

  func verify(_ id: String, input: IPCAgentSetupContinueRequest?) async {
    guard let operation = operations[id], let runtime = operation.runtime,
      operation.snapshot.isRunning
    else { return }
    update(id, state: "verifying", message: "正在验证连接并读取模型目录…")
    do {
      let result = try await dependencies.verify(operation.request, runtime, input)
      try Task.checkCancellation()
      guard operations[id]?.snapshot.isRunning == true else { return }
      operations[id]?.snapshot.installationID = result.installationID
      operations[id]?.snapshot.version = result.version ?? runtime.version
      update(id, state: "ready", message: result.message)
    } catch is CancellationError {
      update(id, state: "cancelled", message: "配置已取消。")
    } catch let error as ServiceAgentSetupError {
      switch error {
      case .userAction(let message):
        update(
          id, state: "needs_user_action", message: Self.redacted(message, input: input),
          userAction: operation.request.providerID == "deepseek-harness" ? "credentials" : "login")
      default:
        update(
          id, state: "failed", message: Self.redacted(error.localizedDescription, input: input))
      }
    } catch {
      update(id, state: "failed", message: Self.redacted(error.localizedDescription, input: input))
    }
  }

  static func redacted(_ message: String, input: IPCAgentSetupContinueRequest?) -> String {
    guard let key = input?.apiKey, !key.isEmpty else { return message }
    return message.replacingOccurrences(of: key, with: "[已隐藏]")
  }
}
