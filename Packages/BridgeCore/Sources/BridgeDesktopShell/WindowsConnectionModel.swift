#if os(Windows) || os(Linux)
  import Foundation
  import BridgeDesktopUI
  import BridgeIPC
  import BridgeMCP
  import BridgeServiceAppCore

  @MainActor
  final class WindowsConnectionModel {
    static let exposureModes: [MCPServiceExposureMode] = [.readOnly, .full]

    let client: any BridgeServiceClientProtocol
    let displayBox: AuxiliaryDisplayBox<WindowsConnectionDisplay>
    let feedback: WindowsDesktopFeedbackStore
    var connectionState = WindowsWorkbenchDisplay.ConnectionState.idle
    var serviceStatus: IPCServiceStatusResponse?
    var clients: [IPCMCPClientStatus] = []
    var geminiCloudStatus: IPCGeminiCloudStatus?
    var deepSeekHarnessMCPServers: [IPCDeepSeekHarnessMCPServerSummary] = []
    var selectedAgentMCPScope = BridgeDesktopAgentMCPScope.deepSeekHarness.rawValue
    private var pendingAgentMCPScopeRefresh = false
    var selectedClientID: String?
    var busy = false
    var statusText = "尚未读取 MCP 客户端状态。"

    init(
      client: any BridgeServiceClientProtocol,
      feedback: WindowsDesktopFeedbackStore
    ) {
      self.client = client
      self.feedback = feedback
      displayBox = AuxiliaryDisplayBox(value: Self.emptyDisplay)
    }

    func applyServiceStatus(
      _ status: IPCServiceStatusResponse?,
      connectionState: WindowsWorkbenchDisplay.ConnectionState
    ) {
      guard serviceStatus != status || self.connectionState != connectionState else { return }
      serviceStatus = status
      self.connectionState = connectionState
      publishDisplay()
    }

    func refresh() async {
      guard !busy else {
        pendingAgentMCPScopeRefresh = true
        return
      }
      busy = true
      pendingAgentMCPScopeRefresh = false
      statusText = "正在读取 MCP 客户端状态…"
      publishDisplay()
      let requestedMCPScope = selectedAgentMCPScope
      defer {
        busy = false
        publishDisplay()
        if pendingAgentMCPScopeRefresh {
          pendingAgentMCPScopeRefresh = false
          Task { @MainActor [weak self] in await self?.refresh() }
        }
      }
      do {
        async let statusRequest = client.status()
        async let clientsRequest = client.mcpClients()
        async let cloudRequest = try? await client.geminiCloudStatus()
        async let deepSeekHarnessMCPRequest = client.deepSeekHarnessMCPServers(
          scope: requestedMCPScope
        )
        serviceStatus = try await statusRequest
        clients = try await clientsRequest
        geminiCloudStatus = await cloudRequest
        if let deepSeekHarnessMCPResponse = try? await deepSeekHarnessMCPRequest,
          selectedAgentMCPScope == requestedMCPScope
        {
          deepSeekHarnessMCPServers = deepSeekHarnessMCPResponse.servers
        }
        connectionState = .connected
        reconcileSelection()
        statusText = "MCP 客户端状态已刷新。"
      } catch {
        connectionState = .unavailable
        statusText = "MCP 状态读取失败：\(BridgeServiceErrorMessage.message(error))"
      }
    }

    func selectClient(at index: Int) {
      guard clients.indices.contains(index) else { return }
      selectedClientID = clients[index].clientID
      publishDisplay()
    }

    func selectAgentMCPScope(_ scope: String) {
      guard BridgeDesktopAgentMCPScope(rawValue: scope) != nil,
        selectedAgentMCPScope != scope
      else { return }
      selectedAgentMCPScope = scope
      deepSeekHarnessMCPServers = []
      pendingAgentMCPScopeRefresh = true
      publishDisplay()
      if !busy {
        Task { @MainActor [weak self] in await self?.refresh() }
      }
    }

    func rotateEndpoint() async {
      await mutate("正在重新生成本地 MCP Endpoint…", success: "本地 MCP Endpoint 已重新生成。") {
        _ = try await self.client.rotateLocalMCPEndpoint()
      }
    }

    /// Applies a user-configured Codex executable; an empty path restores discovery.
    func setCodexExecutablePath(_ path: String?) async {
      let configured = (path?.isEmpty ?? true) ? nil : path
      await mutate(
        "正在更新 Codex 可执行文件…",
        success: configured == nil ? "Codex 已恢复自动发现。" : "Codex 可执行文件已更新。"
      ) {
        self.serviceStatus = try await self.client.setCodexExecutablePath(configured)
      }
    }

    func saveDeepSeekHarnessMCPServer(
      _ request: IPCDeepSeekHarnessMCPServerInput
    ) async {
      let scope = request.scope ?? BridgeDesktopAgentMCPScope.deepSeekHarness.rawValue
      guard scope == selectedAgentMCPScope,
        let scopeValue = BridgeDesktopAgentMCPScope(rawValue: scope)
      else { return }
      await mutate(
        "正在保存 Agent MCP…",
        success: "\(scopeValue.displayName) MCP 已保存。"
      ) {
        _ = try await self.client.saveDeepSeekHarnessMCPServer(request)
      }
    }

    func deleteDeepSeekHarnessMCPServer(id: String, scope: String) async {
      guard scope == selectedAgentMCPScope,
        deepSeekHarnessMCPServers.contains(where: { $0.id == id })
      else { return }
      await mutate("正在删除 Agent MCP…", success: "Agent MCP 已删除。") {
        try await self.client.deleteDeepSeekHarnessMCPServer(id: id, scope: scope)
      }
    }

    func setDeepSeekHarnessMCPServerEnabled(id: String, enabled: Bool, scope: String) async {
      guard scope == selectedAgentMCPScope else { return }
      guard let server = deepSeekHarnessMCPServers.first(where: { $0.id == id }) else { return }
      let request = IPCDeepSeekHarnessMCPServerInput(
        id: server.id,
        name: server.name,
        enabled: enabled,
        transport: server.transport,
        command: server.command,
        args: server.args,
        url: server.url,
        environment: server.environment.map { IPCDeepSeekHarnessMCPSecretInput(name: $0.name) },
        headers: server.headers.map { IPCDeepSeekHarnessMCPSecretInput(name: $0.name) },
        scope: scope
      )
      await saveDeepSeekHarnessMCPServer(request)
    }

    var localMCPEndpoint: String? {
      Self.safeLocalMCPDescription(from: serviceStatus?.localMCPURL)
    }

    nonisolated static func safeLocalMCPDescription(from raw: String?) -> String? {
      guard let raw, let components = URLComponents(string: raw), let host = components.host else {
        return nil
      }
      let port = components.port.map { ":\($0)" } ?? ""
      return "\(components.scheme ?? "http")://\(host)\(port)/mcp"
    }

    func didCopyEndpoint(_ success: Bool) {
      statusText = success ? "已复制本地 MCP Endpoint。" : "复制本地 MCP Endpoint 失败。"
      if success {
        feedback.postToast(statusText)
      } else {
        feedback.postAlert(statusText, title: "复制失败")
      }
      publishDisplay()
    }

    func refreshDisplaySnapshot() { publishDisplay() }

    func mutate(
      _ progress: String,
      success: String,
      action: () async throws -> Void
    ) async {
      guard connectionState == .connected, !busy else { return }
      busy = true
      statusText = progress
      publishDisplay()
      do {
        try await action()
        busy = false
        await refresh()
        statusText = success
        feedback.postToast(success)
        publishDisplay()
      } catch {
        busy = false
        statusText = "操作失败：\(BridgeServiceErrorMessage.message(error))"
        feedback.postAlert(statusText, title: "连接操作失败")
        publishDisplay()
      }
    }

    private var selectedClient: IPCMCPClientStatus? { profile(clientID: nil) }

    func profile(clientID: String?) -> IPCMCPClientStatus? {
      guard let id = clientID ?? selectedClientID else { return nil }
      return clients.first { $0.clientID == id }
    }

    private func reconcileSelection() {
      if let selectedClientID, clients.contains(where: { $0.clientID == selectedClientID }) {
        return
      }
      selectedClientID = clients.first?.clientID
    }

    func publishDisplay() {
      let profile = selectedClient
      let selectedIndex = selectedClientID.flatMap { id in
        clients.firstIndex { $0.clientID == id }
      }
      let localClient = Self.isLocalClient(profile?.clientID)
      let enabled = profile?.enabled == true
      let desktopClients = clients.map { client in
        BridgeDesktopMCPClientRow(
          clientID: client.clientID,
          displayName: client.displayName,
          enabled: client.enabled,
          exposureMode: client.exposureMode.rawValue,
          exposureOptions: Self.exposureModes.map { mode in
            BridgeDesktopChoice(id: mode.rawValue, title: mode == .full ? "完整" : "只读")
          },
          activeSessionCount: client.activeSessionCount,
          lastConnectedAt: client.lastConnectedAt,
          canToggle: Self.isLocalClient(client.clientID) && !busy,
          canCopyConfiguration: Self.isLocalClient(client.clientID)
            && client.enabled && !busy,
          canRotateCredential: Self.isLocalClient(client.clientID)
            && client.enabled && !busy
        )
      }
      displayBox.store(
        WindowsConnectionDisplay(
          connectionState: connectionState,
          clientRows: clients.map {
            "\($0.displayName) — \($0.enabled ? "已启用" : "已停用") · Session \($0.activeSessionCount)"
          },
          selectedClientIndex: selectedIndex,
          clientDetailText: detailText(profile),
          endpointText: localMCPEndpoint ?? "本地 MCP Endpoint 暂不可用",
          exposureRows: ["只读", "完整"],
          selectedExposureIndex: profile.flatMap {
            Self.exposureModes.firstIndex(of: $0.exposureMode)
          },
          toggleTitle: localClient
            ? (enabled ? "停用 \(profile?.displayName ?? "")" : "启用 \(profile?.displayName ?? "")")
            : "ChatGPT 保持启用",
          toggleEnabled: localClient && !busy,
          saveExposureEnabled: enabled && !busy,
          copyConfigurationEnabled: localClient && enabled && !busy,
          rotateCredentialEnabled: localClient && enabled && !busy,
          rotateEndpointEnabled: connectionState == .connected && !busy,
          statusText: ServiceStatusPresentation.connectionMessage(
            status: serviceStatus?.status,
            currentMessage: statusText
          ) ?? statusText,
          clientItems: desktopClients,
          geminiCloud: projectedGeminiCloud,
          deepSeekHarnessMCPItems: deepSeekHarnessMCPServers.map { server in
            BridgeDesktopDeepSeekHarnessMCPRow(
              id: server.id,
              name: server.name,
              enabled: server.enabled,
              transport: server.transport,
              command: server.command,
              arguments: server.args,
              url: server.url,
              environment: server.environment.map {
                BridgeDesktopSecretSummary(name: $0.name, hasValue: $0.hasValue)
              },
              headers: server.headers.map {
                BridgeDesktopSecretSummary(name: $0.name, hasValue: $0.hasValue)
              },
              canToggle: !busy,
              canEdit: !busy,
              canDelete: !busy
            )
          },
          selectedAgentMCPScope: selectedAgentMCPScope,
          agentMCPScopeOptions: BridgeDesktopAgentMCPScope.allCases.map(\.choice),
          tunnel: projectedTunnel,
          codexExecutablePath: serviceStatus?.status.codexExecutablePath,
          codexResolvedExecutablePath: serviceStatus?.status.codexResolvedExecutablePath
        )
      )
    }

    private func detailText(_ profile: IPCMCPClientStatus?) -> String {
      guard let profile else { return "请选择 MCP 客户端。" }
      let permission = profile.exposureMode == .full ? "完整" : "只读"
      return [
        "客户端：\(profile.displayName)",
        "状态：\(profile.enabled ? "已启用" : "已停用")",
        "工具权限：\(permission)",
        "活动 Session：\(profile.activeSessionCount)",
        "最近连接：\(profile.lastConnectedAt ?? "无")",
        "",
        profile.exposureMode == .full
          ? "暴露任务与 Direct 工具；项目权限、workspace gate 与本机审批仍然生效。"
          : "仅暴露项目、文件、任务、Thread、模型与 Skill 查询工具。",
      ].joined(separator: "\r\n")
    }

    private static let emptyDisplay = WindowsConnectionDisplay(
      connectionState: .idle,
      clientRows: [],
      selectedClientIndex: nil,
      clientDetailText: "请选择 MCP 客户端。",
      endpointText: "—",
      exposureRows: ["只读", "完整"],
      selectedExposureIndex: nil,
      toggleTitle: "启用 Qwen Studio",
      toggleEnabled: false,
      saveExposureEnabled: false,
      copyConfigurationEnabled: false,
      rotateCredentialEnabled: false,
      rotateEndpointEnabled: false,
      statusText: "尚未读取 MCP 客户端状态。"
    )
  }
#endif
