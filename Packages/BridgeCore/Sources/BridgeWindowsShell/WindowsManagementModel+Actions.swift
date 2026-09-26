#if os(Windows)
  import BridgeIPC
  import BridgeServiceAppCore
  import Foundation

  extension WindowsManagementModel {
    func registerProject(name: String, path: String) async {
      let projectName = name.trimmingCharacters(in: .whitespacesAndNewlines)
      let absolutePath = path.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !projectName.isEmpty, !absolutePath.isEmpty else {
        reportProjectFailure("项目名称和绝对路径不能为空。")
        return
      }
      guard connectionState == .connected else {
        reportProjectFailure("后台 Service 未连接，无法注册项目。")
        return
      }
      guard !projectBusy else { return }
      setProjectBusy(true)
      setProjectStatus("正在注册项目…")
      defer { setProjectBusy(false) }
      do {
        let detail = try await client.registerProject(
          IPCProjectRegistrationRequest(name: projectName, absolutePath: absolutePath)
        )
        selectedProjectID = detail.projectID
        await refreshProjects()
        reportProjectSuccess("项目已注册：\(detail.name)")
      } catch {
        reportProjectFailure("项目注册失败：\(BridgeServiceErrorMessage.message(error))")
      }
    }

    func removeSelectedProject(projectID requestedProjectID: String? = nil) async {
      guard let projectID = requestedProjectID ?? selectedProjectID,
        let project = projects.first(where: { $0.projectID == projectID })
      else {
        reportProjectFailure("请先选择要移除的项目。")
        return
      }
      guard connectionState == .connected else {
        reportProjectFailure("后台 Service 未连接，无法移除项目。")
        return
      }
      guard !projectBusy else { return }
      setProjectBusy(true)
      setProjectStatus("正在移除项目…")
      defer { setProjectBusy(false) }
      do {
        try await client.removeProject(projectID: projectID)
        if selectedProjectID == projectID { selectedProjectID = nil }
        await refreshProjects()
        reportProjectSuccess("已移除项目：\(project.name)", projectID: projectID)
      } catch {
        reportProjectFailure(
          "项目移除失败：\(BridgeServiceErrorMessage.message(error))", projectID: projectID)
      }
    }

    func saveSelectedProjectPolicy(
      read: String,
      write: String,
      network: String,
      projectID requestedProjectID: String? = nil
    ) async {
      guard let projectID = requestedProjectID ?? selectedProjectID else {
        reportProjectFailure("请先选择要保存策略的项目。")
        return
      }
      guard connectionState == .connected else {
        reportProjectFailure("后台 Service 未连接，无法保存项目策略。")
        return
      }
      guard !projectBusy else { return }
      setProjectBusy(true)
      setProjectStatus("正在保存项目策略…")
      defer { setProjectBusy(false) }
      do {
        _ = try await client.updateProjectPolicy(
          IPCProjectPolicyRequest(
            projectID: projectID,
            readPermission: read,
            writePermission: write,
            networkPermission: network
          )
        )
        await refreshProjects()
        reportProjectSuccess("项目策略已保存生效。", projectID: projectID)
      } catch {
        reportProjectFailure(
          "项目策略保存失败：\(BridgeServiceErrorMessage.message(error))", projectID: projectID)
      }
    }

    func connectAgent(
      providerID: String,
      baseURL: String? = nil,
      apiKey: String? = nil,
      alwaysProceedConfirmed: Bool = false,
      qoderDistribution: String? = nil,
      installationID: String? = nil
    ) async {
      guard let provider = agentProviders.first(where: { $0.providerID == providerID }) else {
        reportAgentFailure("未找到可连接的 Agent Provider。")
        return
      }
      let hasExistingInstallation = agentInstallations.contains {
        $0.providerID == providerID
      }
      guard
        AgentConnectionInput.isValid(
          providerRequiresConfiguration: provider.requiresConfiguration,
          hasExistingInstallation: hasExistingInstallation,
          baseURL: baseURL,
          apiKey: apiKey,
          hasExistingConfiguration: provider.discoveredConfigurationPath != nil
        )
      else {
        reportAgentFailure("请填写 \(provider.displayName) 的 Base URL 和 API key。")
        return
      }
      guard connectionState == .connected else {
        reportAgentFailure("后台 Service 未连接，无法连接 Agent。")
        return
      }
      guard !agentBusy else { return }
      setAgentBusy(true)
      setAgentStatus("正在自动发现并连接 Agent…")
      do {
        let installation = try await client.connectAgentInstallation(
          providerID: provider.providerID,
          baseURL: AgentConnectionInput.baseURL(baseURL),
          apiKey: AgentConnectionInput.apiKey(apiKey),
          alwaysProceedConfirmed: alwaysProceedConfirmed,
          qoderDistribution: qoderDistribution,
          installationID: installationID
        )
        selectedProviderID = provider.providerID
        selectedInstallationID = installation.installationID
        setAgentBusy(false)
        await refreshAgents()
        let state = ProjectAgentPresentation.availabilityLabel(installation.availability)
        if installation.availability == "available" {
          reportAgentSuccess("已连接并验证 \(installation.displayName)。")
        } else {
          reportAgentFailure(
            "Agent 已发现，但检查状态为 \(state)。",
            installationID: installation.installationID
          )
        }
      } catch {
        setAgentBusy(false)
        reportAgentFailure("Agent 连接失败：\(BridgeServiceErrorMessage.message(error))")
      }
    }

    func registerAgent(
      providerID: String,
      executablePath: String,
      configurationPath: String,
      displayName: String? = nil,
      qoderDistribution: String? = nil
    ) async {
      let executable = executablePath.trimmingCharacters(in: .whitespacesAndNewlines)
      let configuration = configurationPath.trimmingCharacters(in: .whitespacesAndNewlines)
      guard let provider = agentProviders.first(where: { $0.providerID == providerID }) else {
        reportAgentFailure("请选择有效的 Provider。")
        return
      }
      let requestedName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      guard !requestedName.contains("\0"), requestedName.utf8.count <= 256 else {
        reportAgentFailure("Agent 显示名称无效。")
        return
      }
      let effectiveName = requestedName.isEmpty ? provider.displayName : requestedName
      guard !executable.isEmpty else {
        reportAgentFailure("Agent 可执行文件路径不能为空。")
        return
      }
      guard !provider.requiresConfiguration || !configuration.isEmpty else {
        reportAgentFailure("当前 Provider 需要配置文件路径。")
        return
      }
      guard connectionState == .connected else {
        reportAgentFailure("后台 Service 未连接，无法登记 Agent。")
        return
      }
      guard !agentBusy else { return }
      setAgentBusy(true)
      setAgentStatus("正在添加并检查 Agent…")
      do {
        let installation = try await client.registerAgentInstallation(
          IPCAgentRegistrationRequest(
            providerID: provider.providerID,
            displayName: effectiveName,
            executablePath: executable,
            configurationPath: configuration.isEmpty ? nil : configuration,
            qoderDistribution: qoderDistribution
          )
        )
        selectedInstallationID = installation.installationID
        setAgentBusy(false)
        await refreshAgents()
        let state = ProjectAgentPresentation.availabilityLabel(installation.availability)
        let successNote =
          installation.availability == "available"
          ? "已登记并验证 \(installation.displayName)，确认启用后才会进入可选目录。"
          : "Agent 已登记：\(installation.displayName)（\(state)）。"
        reportAgentSuccess(successNote)
      } catch {
        setAgentBusy(false)
        reportAgentFailure("Agent 登记失败：\(BridgeServiceErrorMessage.message(error))")
      }
    }

    func setQoderRuntimeSettings(_ request: IPCAgentQoderRuntimeSettingsRequest) async {
      guard connectionState == .connected else {
        reportAgentFailure("后台 Service 未连接，无法保存 Qoder 配置。")
        return
      }
      guard !agentBusy else { return }
      setAgentBusy(true)
      do {
        _ = try await client.setQoderRuntimeSettings(request)
        setAgentBusy(false)
        await refreshAgents()
        reportAgentSuccess("Qoder 地区与 SDK 配置已保存。")
      } catch {
        setAgentBusy(false)
        reportAgentFailure("Qoder 配置保存失败：\(BridgeServiceErrorMessage.message(error))")
      }
    }

    func setSelectedAgentEnabled(_ enabled: Bool, installationID requestedID: String? = nil) async {
      guard let installationID = requestedID ?? selectedInstallationID,
        let installation = agentInstallations.first(where: { $0.installationID == installationID })
      else {
        reportAgentFailure("请先选择要启停的 Agent 安装。")
        return
      }
      guard !enabled || installation.availability == "available" else {
        reportAgentFailure("请先通过连接检查。")
        return
      }
      guard connectionState == .connected else {
        reportAgentFailure("后台 Service 未连接，无法更改 Agent 状态。")
        return
      }
      guard !agentBusy else { return }
      setAgentBusy(true)
      setAgentStatus(enabled ? "正在启用 Agent…" : "正在停用 Agent…")
      defer { setAgentBusy(false) }
      do {
        _ = try await client.setAgentInstallationEnabled(
          installationID: installationID,
          enabled: enabled
        )
        await refreshAgents()
        reportAgentSuccess(enabled ? "Agent 已连接。" : "Agent 已断开。", installationID: installationID)
      } catch {
        reportAgentFailure(
          "Agent 启停失败：\(BridgeServiceErrorMessage.message(error))", installationID: installationID)
      }
    }

    func reprobeSelectedAgent(acceptReplacement: Bool, installationID requestedID: String? = nil)
      async
    {
      guard let installationID = requestedID ?? selectedInstallationID else {
        reportAgentFailure("请先选择要检查的 Agent。")
        return
      }
      guard connectionState == .connected else {
        reportAgentFailure("后台 Service 未连接，无法检查 Agent。")
        return
      }
      guard !agentBusy else { return }
      setAgentBusy(true)
      setAgentStatus(acceptReplacement ? "正在确认更新并检查…" : "正在检查 Agent…")
      defer { setAgentBusy(false) }
      do {
        let installation = try await client.reprobeAgentInstallation(
          installationID: installationID,
          acceptReplacement: acceptReplacement
        )
        await refreshAgents()
        let state = ProjectAgentPresentation.availabilityLabel(installation.availability)
        reportAgentSuccess("检查完成：\(state)。", installationID: installationID)
      } catch {
        reportAgentFailure(
          "Agent 检查失败：\(BridgeServiceErrorMessage.message(error))",
          installationID: installationID)
      }
    }

    func removeSelectedAgent(installationID requestedID: String? = nil) async {
      guard let installationID = requestedID ?? selectedInstallationID else {
        reportAgentFailure("请先选择要移除的 Agent 安装。")
        return
      }
      guard connectionState == .connected else {
        reportAgentFailure("后台 Service 未连接，无法移除 Agent。")
        return
      }
      guard !agentBusy else { return }
      setAgentBusy(true)
      setAgentStatus("正在移除 Agent 连接…")
      defer { setAgentBusy(false) }
      do {
        try await client.removeAgentInstallation(installationID: installationID)
        if selectedInstallationID == installationID { selectedInstallationID = nil }
        await refreshAgents()
        reportAgentSuccess("Agent 安装登记已移除。", installationID: installationID)
      } catch {
        reportAgentFailure(
          "Agent 移除失败：\(BridgeServiceErrorMessage.message(error))", installationID: installationID)
      }
    }
  }
#endif
