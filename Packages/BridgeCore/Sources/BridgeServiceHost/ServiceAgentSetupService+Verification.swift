import BridgeAgentCore
import BridgeIPC
import BridgeServiceCore
import Foundation

extension ServiceAgentSetupService {
  func verify(
    _ request: IPCAgentSetupRequest, runtime: ServiceAgentSetupRuntime,
    input: IPCAgentSetupContinueRequest?
  ) async throws -> ServiceAgentSetupVerification {
    let providerID = AgentProviderID(rawValue: request.providerID)
    let previous = try await registry.installations(providerID: providerID).first {
      Self.matchesExecutable($0.executablePath, runtime.executablePath)
    }
    do {
      try Task.checkCancellation()
      try await requireIdleConfiguration(providerID, input: input)
      try await configure(request, runtime: runtime)
      let distribution = request.qoderDistribution.flatMap(QoderDistribution.init(rawValue:))
      if let distribution {
        await stageQoder(runtime, previous: previous, distribution: distribution)
      }
      let record = try await connect(request, runtime: runtime, previous: previous, input: input)
      try Task.checkCancellation()
      if [.openCode, .pi, .antigravity].contains(providerID), previous?.isSelectable != true,
        input?.loginCompleted != true
      {
        throw ServiceAgentSetupError.userAction("安装与接口已准备，请完成原生登录或确认已有登录，再验证连接。")
      }
      try await verifyModels(record)
      try Task.checkCancellation()
      if let distribution {
        try await selectQoder(record, runtime: runtime, distribution: distribution)
      }
      _ = await discovery.summaries(
        providerIDs: [providerID], existingInstallations: try await registry.installations(),
        forceRefresh: true)
      return ServiceAgentSetupVerification(
        installationID: record.id.rawValue, version: record.version,
        message: providerID == .qoder
          ? "配置完成，原生账号与模型目录已验证。"
          : "配置完成，接口与模型目录已检测。认证和额度以实际任务结果为准。")
    } catch {
      await bindings.remove(runtime.executablePath)
      if previous?.isSelectable != true,
        let record = try? await registry.installations(providerID: providerID).first(where: {
          Self.matchesExecutable($0.executablePath, runtime.executablePath)
        })
      {
        _ = try? await registry.setEnabled(false, installationID: record.id)
      }
      throw error
    }
  }

  private func requireIdleConfiguration(
    _ providerID: AgentProviderID, input: IPCAgentSetupContinueRequest?
  ) async throws {
    let changesCredentials =
      providerID == .deepSeekHarness
      && (input?.baseURL != nil || input?.apiKey != nil || input?.inferenceProtocol != nil)
    let changesPermission = providerID == .antigravity && input?.alwaysProceedConfirmed == true
    guard changesCredentials || changesPermission else { return }
    guard try await tasks.nonterminalTasks().allSatisfy({ $0.providerID != providerID.rawValue })
    else {
      throw ServiceAgentSetupError.unavailable("此 Agent 仍有未结束的任务，请结束任务后再更新配置。")
    }
  }

  private func connect(
    _ request: IPCAgentSetupRequest, runtime: ServiceAgentSetupRuntime,
    previous: ServiceAgentInstallationRecord?, input: IPCAgentSetupContinueRequest?
  ) async throws -> ServiceAgentInstallationRecord {
    let providerID = AgentProviderID(rawValue: request.providerID)
    let candidates = try await registrationRequests(request, runtime: runtime, input: input)
    guard !candidates.isEmpty else {
      throw ServiceAgentSetupError.unavailable("已安装的程序入口无法登记，请检查运行时布局。")
    }
    if providerID == .deepSeekHarness, input == nil, previous?.isSelectable != true,
      try await settings.deepSeekHarnessConnectionConfiguration() == nil
    {
      throw ServiceAgentSetupError.userAction("DSH 运行时与配置已准备，请填写 API Key 和服务地址。")
    }
    let confirmed = try await permissionConfirmed(providerID, previous: previous, input: input)
    do {
      let record = try await application.serviceConnectManagedAgent(
        providerID: providerID, baseURL: input?.baseURL, apiKey: input?.apiKey,
        candidates: candidates,
        inferenceProtocol: input?.inferenceProtocol.flatMap(
          DeepSeekHarnessConnectionProtocol.init(rawValue:)),
        catalogBaseURL: input?.catalogBaseURL,
        qoderDistribution: request.qoderDistribution.flatMap(QoderDistribution.init(rawValue:)),
        alwaysProceedConfirmed: confirmed, selectQoderInstallation: false,
        deadline: ContinuousClock.now.advanced(by: .seconds(90)))
      guard record.availability == .available else {
        throw ServiceAgentSetupError.unavailable(record.lastProbeError ?? "Agent 接口验证失败。")
      }
      return record
    } catch {
      throw ServiceAgentSetupErrorPresentation.present(error, providerID: providerID)
    }
  }

  private func verifyModels(_ record: ServiceAgentInstallationRecord) async throws {
    do {
      let models = try await application.serviceListAgentModels(
        installationID: record.id, useStoredDefault: false, forceRefresh: true,
        deadline: ContinuousClock.now.advanced(by: .seconds(90)))
      guard !models.isEmpty else {
        throw ServiceAgentSetupError.userAction("运行时已连接，当前没有可用模型，请完成原生登录或服务商配置。")
      }
    } catch {
      throw ServiceAgentSetupErrorPresentation.present(error, providerID: record.providerID)
    }
  }

  private func stageQoder(
    _ runtime: ServiceAgentSetupRuntime, previous: ServiceAgentInstallationRecord?,
    distribution: QoderDistribution
  ) async {
    let artifacts = previous?.isSelectable == true ? previous?.artifacts ?? [] : []
    let node = artifacts.first(where: { $0.role == .nodeInterpreter })?.canonicalPath
    let sdk = artifacts.first(where: { $0.role == .runtimeManifest }).map {
      URL(fileURLWithPath: $0.canonicalPath).deletingLastPathComponent().path
    }
    await bindings.stage(
      ServiceAgentSetupRuntime(
        executablePath: runtime.executablePath,
        nodeExecutablePath: node ?? runtime.nodeExecutablePath,
        sdkRoot: sdk ?? runtime.sdkRoot, version: runtime.version,
        installationDirectory: runtime.installationDirectory), distribution: distribution)
  }

  private func selectQoder(
    _ record: ServiceAgentInstallationRecord, runtime: ServiceAgentSetupRuntime,
    distribution: QoderDistribution
  ) async throws {
    let staged = await bindings.staged(for: runtime.executablePath)
    try await settings.setQoderRuntimeSettings(
      ServiceQoderRuntimeSettings(
        distribution: distribution, activeInstallationID: record.id.rawValue,
        nodeExecutablePath: staged?.nodeExecutablePath, sdkRoot: staged?.sdkRoot))
    await bindings.remove(runtime.executablePath)
  }

  private func permissionConfirmed(
    _ providerID: AgentProviderID, previous: ServiceAgentInstallationRecord?,
    input: IPCAgentSetupContinueRequest?
  ) async throws -> Bool {
    if input?.alwaysProceedConfirmed == true { return true }
    guard providerID == .antigravity, let previous else { return false }
    return try await registry.nativePermissionPolicy(installationID: previous.id).toolPermission
      == "always-proceed"
  }

}
