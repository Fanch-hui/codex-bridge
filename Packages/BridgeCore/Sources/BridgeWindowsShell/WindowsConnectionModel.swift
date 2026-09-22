#if os(Windows)
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
    var deepSeekHarnessMCPServers: [IPCDeepSeekHarnessMCPServerSummary] = []
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
      guard !busy else { return }
      busy = true
      statusText = "正在读取 MCP 客户端状态…"
      publishDisplay()
      defer {
        busy = false
        publishDisplay()
      }
      do {
        async let statusRequest = client.status()
        async let clientsRequest = client.mcpClients()
        async let deepSeekHarnessMCPRequest = client.deepSeekHarnessMCPServers()
        serviceStatus = try await statusRequest
        clients = try await clientsRequest
        if let deepSeekHarnessMCPResponse = try? await deepSeekHarnessMCPRequest {
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

    func toggleSelectedClient(clientID: String? = nil) async {
      guard let profile = profile(clientID: clientID),
        profile.clientID == MCPClientID.qwenStudio.rawValue
      else {
        return
      }
      let enabled = !profile.enabled
      await mutate(
        "正在更新 Qwen Studio 状态…",
        success: enabled ? "Qwen Studio 已启用。" : "Qwen Studio 已停用。"
      ) {
        try await self.client.setMCPClientEnabled(
          clientID: profile.clientID,
          enabled: enabled
        )
      }
    }

    func setSelectedExposure(at index: Int, clientID: String? = nil) async {
      guard Self.exposureModes.indices.contains(index), let profile = profile(clientID: clientID)
      else { return }
      let mode = Self.exposureModes[index]
      await mutate(
        "正在保存工具权限…",
        success: "工具权限已设置为：\(mode == .full ? "完整" : "只读")。"
      ) {
        if profile.clientID == MCPClientID.chatGPT.rawValue {
          try await self.client.setExposureMode(mode)
        } else {
          try await self.client.setMCPClientExposureMode(clientID: profile.clientID, mode: mode)
        }
      }
    }

    func exportSelectedConfiguration(clientID: String? = nil) async -> String? {
      guard let profile = profile(clientID: clientID),
        profile.clientID == MCPClientID.qwenStudio.rawValue,
        profile.enabled
      else { return nil }
      do {
        let value = try await client.exportMCPClientConfiguration(clientID: profile.clientID)
        statusText = "Qwen JSON 配置已生成。"
        publishDisplay()
        return value
      } catch {
        statusText = "生成 Qwen 配置失败：\(BridgeServiceErrorMessage.message(error))"
        feedback.postAlert(statusText, title: "配置生成失败")
        publishDisplay()
        return nil
      }
    }

    func rotateSelectedCredential(clientID: String? = nil) async {
      guard let profile = profile(clientID: clientID),
        profile.clientID == MCPClientID.qwenStudio.rawValue,
        profile.enabled
      else { return }
      await mutate("正在重新生成 Qwen 凭证…", success: "Qwen 凭证已重新生成。") {
        try await self.client.rotateMCPClientCredential(clientID: profile.clientID)
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
      await mutate("正在保存 DSH MCP…", success: "DSH MCP 已保存。") {
        _ = try await self.client.saveDeepSeekHarnessMCPServer(request)
      }
    }

    func deleteDeepSeekHarnessMCPServer(id: String) async {
      await mutate("正在删除 DSH MCP…", success: "DSH MCP 已删除。") {
        try await self.client.deleteDeepSeekHarnessMCPServer(id: id)
      }
    }

    func setDeepSeekHarnessMCPServerEnabled(id: String, enabled: Bool) async {
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
        headers: server.headers.map { IPCDeepSeekHarnessMCPSecretInput(name: $0.name) }
      )
      await saveDeepSeekHarnessMCPServer(request)
    }

    func didCopyConfiguration(_ success: Bool) {
      statusText = success ? "已复制 Qwen Studio JSON 配置。" : "复制 Qwen 配置失败。"
      if success {
        feedback.postToast(statusText)
      } else {
        feedback.postAlert(statusText, title: "复制失败")
      }
      publishDisplay()
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

    private func profile(clientID: String?) -> IPCMCPClientStatus? {
      guard let id = clientID ?? selectedClientID else { return nil }
      return clients.first { $0.clientID == id }
    }

    private func reconcileSelection() {
      if let selectedClientID, clients.contains(where: { $0.clientID == selectedClientID }) {
        return
      }
      selectedClientID = clients.first?.clientID
    }

    private func publishDisplay() {
      let profile = selectedClient
      let selectedIndex = selectedClientID.flatMap { id in
        clients.firstIndex { $0.clientID == id }
      }
      let isQwen = profile?.clientID == MCPClientID.qwenStudio.rawValue
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
          canToggle: client.clientID == MCPClientID.qwenStudio.rawValue && !busy,
          canCopyConfiguration: client.clientID == MCPClientID.qwenStudio.rawValue
            && client.enabled && !busy,
          canRotateCredential: client.clientID == MCPClientID.qwenStudio.rawValue
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
          toggleTitle: isQwen
            ? (enabled ? "停用 Qwen Studio" : "启用 Qwen Studio")
            : "ChatGPT 保持启用",
          toggleEnabled: isQwen && !busy,
          saveExposureEnabled: enabled && !busy,
          copyConfigurationEnabled: isQwen && enabled && !busy,
          rotateCredentialEnabled: isQwen && enabled && !busy,
          rotateEndpointEnabled: connectionState == .connected && !busy,
          statusText: ServiceStatusPresentation.connectionMessage(
            status: serviceStatus?.status,
            currentMessage: statusText
          ) ?? statusText,
          clientItems: desktopClients,
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
