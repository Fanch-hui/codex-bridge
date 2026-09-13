import BridgeIPC
import BridgeServiceAppCore
import Foundation

extension BridgeServiceAppModel {
  func registerAgentInstallation(
    providerID: String,
    displayName: String,
    executableURL: URL,
    configurationURL: URL? = nil
  ) {
    runAgentMutation(
      operation: { client in
        try await client.registerAgentInstallation(
          IPCAgentRegistrationRequest(
            providerID: providerID,
            displayName: displayName,
            executablePath: executableURL.standardizedFileURL.path,
            configurationPath: configurationURL?.standardizedFileURL.path
          )
        )
      },
      successMessage: { installation in
        let name = installation?.displayName ?? displayName
        return installation?.availability == "available"
          ? "已登记并验证 \(name)，点击连接后即可使用"
          : "已登记 \(name)，但连接检查未通过"
      }
    )
  }

  func connectAgentInstallation(
    providerID: String,
    baseURL: String? = nil,
    apiKey: String? = nil,
    alwaysProceedConfirmed: Bool = false
  ) {
    guard let provider = agentProviders.first(where: { $0.providerID == providerID }) else {
      errorMessage = "未找到可连接的 Agent Provider。"
      return
    }
    runAgentMutation(
      operation: { client in
        try await client.connectAgentInstallation(
          providerID: provider.providerID,
          baseURL: baseURL,
          apiKey: apiKey,
          alwaysProceedConfirmed: alwaysProceedConfirmed
        )
      },
      successMessage: { installation in
        guard let installation else { return "Agent 连接请求已完成" }
        return installation.availability == "available"
          ? "已连接并验证 \(installation.displayName)"
          : "已发现 \(installation.displayName)，但连接检查未通过"
      }
    )
  }

  func reprobeAgentInstallation(
    _ installationID: String,
    acceptReplacement: Bool
  ) {
    runAgentMutation(
      operation: { client in
        try await client.reprobeAgentInstallation(
          installationID: installationID,
          acceptReplacement: acceptReplacement
        )
      },
      successMessage: { installation in
        installation?.availability == "available"
          ? "Agent 检查通过"
          : "Agent 检查未通过，请查看原因"
      }
    )
  }

  func setAgentInstallationEnabled(_ installationID: String, enabled: Bool) {
    runAgentMutation(
      operation: { client in
        try await client.setAgentInstallationEnabled(
          installationID: installationID,
          enabled: enabled
        )
      },
      successMessage: { installation in
        installation?.isEnabled == true ? "Agent 已连接" : "Agent 已断开"
      }
    )
  }

  func removeAgentInstallation(_ installationID: String) {
    runAgentMutation(
      operation: { client in
        try await client.removeAgentInstallation(installationID: installationID)
        return nil
      },
      successMessage: { _ in "已移除 Agent 连接" }
    )
  }

  private func runAgentMutation(
    operation:
      @escaping @MainActor @Sendable (any BridgeServiceClientProtocol) async throws
      -> IPCAgentInstallationSummary?,
    successMessage: @escaping @MainActor @Sendable (IPCAgentInstallationSummary?) -> String
  ) {
    guard !isManagingAgents else { return }
    isManagingAgents = true
    errorMessage = nil
    Task { [weak self] in
      guard let self else { return }
      defer {
        self.isManagingAgents = false
        self.agentOperationRevision &+= 1
      }
      do {
        let client = try self.currentClient()
        let installation = try await operation(client)
        let catalog = try await client.agentCatalog()
        self.agentProviders = catalog.providers
        self.agentInstallations = catalog.installations
        if let installation, installation.isEnabled, installation.availability == "available" {
          self.refreshAgentModelCatalog(
            installationID: installation.installationID, providerID: installation.providerID)
        }
        let isSuccess = installation?.availability == "available" || installation == nil
        self.postToast(
          successMessage(installation),
          symbol: isSuccess ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
          tone: isSuccess ? .success : .warning
        )
      } catch {
        self.errorMessage = Self.message(error)
      }
    }
  }
}
