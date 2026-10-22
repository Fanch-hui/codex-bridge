public enum BridgeDesktopOverviewPresentation {
  public static func clientConnections(
    clients: [BridgeDesktopMCPClientRow], serviceAvailable: Bool, localMCPReady: Bool,
    tunnel: BridgeDesktopTunnelState?, geminiCloud: BridgeDesktopGeminiCloudState?
  ) -> [BridgeDesktopServiceRow] {
    clients.filter(\.enabled).map { client in
      let status = clientStatus(
        client, serviceAvailable: serviceAvailable, localMCPReady: localMCPReady,
        tunnel: tunnel, geminiCloud: geminiCloud)
      return BridgeDesktopServiceRow(
        id: client.clientID, title: clientTitle(client), value: status.label,
        symbol: status.tone == .success ? "checkmark.circle.fill" : "link",
        tone: status.tone, destination: .connections)
    }
  }

  public static func onboardingSteps(
    hasProjects: Bool, hasConfiguredClient: Bool
  ) -> [BridgeDesktopActionLink] {
    guard !hasProjects || !hasConfiguredClient else { return [] }
    return [
      BridgeDesktopActionLink(
        id: "register-project", title: "登记项目", command: .openProjects, destination: .projects),
      BridgeDesktopActionLink(
        id: "connect-client", title: "连接聊天客户端", command: .openConnections,
        destination: .connections),
      BridgeDesktopActionLink(
        id: "start-using", title: "开始使用", command: .openWorkbench, destination: .workbench),
    ]
  }

  public static func clientNotices(
    connections: [BridgeDesktopServiceRow], serviceAvailable: Bool
  ) -> [BridgeDesktopNotice] {
    guard serviceAvailable else { return [] }
    return connections.compactMap { row in
      guard row.tone == .warning || row.tone == .error else { return nil }
      return BridgeDesktopNotice(
        id: "client-" + row.id, title: row.title + " 需要处理", message: row.value,
        symbol: "exclamationmark.triangle.fill", tone: row.tone, destination: .connections,
        detailID: clientDetailID(row.id))
    }
  }

  public static func agentNotice(
    installationID: String, providerID: String, displayName: String,
    availability: String, requiresReconnect: Bool
  ) -> BridgeDesktopNotice? {
    let review = availability == "needs_review"
    guard review || requiresReconnect else { return nil }
    return BridgeDesktopNotice(
      id: "agent-" + installationID,
      title: displayName + (review ? " 需要确认更新" : " 需要重新连接"),
      message: review ? "确认当前安装后继续使用。" : "打开连接详情检查并恢复连接。",
      symbol: "exclamationmark.triangle.fill", tone: .warning, destination: .connections,
      detailID: "agent:" + providerID, installationID: installationID)
  }

  public static func setupNotices(
    operations: [BridgeDesktopAgentSetupState]
  ) -> [BridgeDesktopNotice] {
    var scopes = Set<String>()
    let latest = operations.reversed().filter { operation in
      scopes.insert(operation.providerID + ":" + (operation.distribution ?? "")).inserted
    }.reversed()
    return latest.filter {
      $0.state == "needs_user_action" || $0.state == "failed" || $0.state == "interrupted"
    }.map { operation in
      BridgeDesktopNotice(
        id: "setup-" + operation.operationID, title: "Agent 配置需要处理",
        message: operation.message, symbol: "exclamationmark.triangle.fill",
        tone: operation.state == "failed" ? .error : .warning, destination: .connections,
        detailID: "agent:" + operation.providerID,
        distribution: operation.distribution, installationID: operation.installationID)
    }
  }

  private static func clientStatus(
    _ client: BridgeDesktopMCPClientRow, serviceAvailable: Bool, localMCPReady: Bool,
    tunnel: BridgeDesktopTunnelState?, geminiCloud: BridgeDesktopGeminiCloudState?
  ) -> (label: String, tone: BridgeDesktopStatusTone) {
    guard serviceAvailable else { return ("等待后台服务", .neutral) }
    if client.clientID == "openai.chatgpt" {
      guard let tunnel, tunnel.configured else { return ("待配置", .neutral) }
      if tunnel.acceptsRemoteSubmissions { return readyStatus(client) }
      if tunnel.actionRequired { return ("需要处理连接", .warning) }
      if tunnel.lifecycle == "failed" { return ("连接失败", .error) }
      return tunnel.enabled ? ("连接中", .running) : ("未连接", .neutral)
    }
    if client.clientID == "google.gemini", let cloud = geminiCloud, cloud.enabled {
      if cloud.lifecycle == "failed" { return ("云端连接失败", .error) }
      if cloud.hosting == "ngrok" { return ("已配置", .neutral) }
      if cloud.lifecycle == "ready" { return readyStatus(client) }
      return ("云端连接中", .running)
    }
    return localMCPReady ? readyStatus(client) : ("本机连接未就绪", .warning)
  }

  private static func readyStatus(
    _ client: BridgeDesktopMCPClientRow
  ) -> (label: String, tone: BridgeDesktopStatusTone) {
    (client.activeSessionCount > 0 ? "已连接" : "可接入", .success)
  }

  private static func clientTitle(_ client: BridgeDesktopMCPClientRow) -> String {
    switch client.clientID {
    case "openai.chatgpt": "ChatGPT"
    case "qwen.studio": "Qwen Studio"
    case "google.gemini": "Gemini"
    default: client.displayName
    }
  }

  private static func clientDetailID(_ clientID: String) -> String? {
    switch clientID {
    case "openai.chatgpt": "chatgpt"
    case "qwen.studio": "qwen"
    case "google.gemini": "gemini"
    default: nil
    }
  }
}
