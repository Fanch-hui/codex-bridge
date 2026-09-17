import AppKit
import BridgeDesktopUI
import BridgeIPC
import BridgeMCP
import BridgeServiceAppCore

extension BridgeDesktopCommandRouter {
  static func handleConnections(
    _ envelope: BridgeDesktopCommandEnvelope,
    model: BridgeServiceAppModel
  ) {
    let payload = envelope.payload
    switch envelope.command {
    case .setMCPClientEnabled:
      guard connected(model), clientID(payload.clientID) == MCPClientID.qwenStudio.rawValue,
        let enabled = payload.enabled
      else { return }
      model.setQwenStudioEnabled(enabled)
    case .setMCPClientExposure:
      guard connected(model), let clientID = clientID(payload.clientID),
        let rawMode = validatedID(payload.exposureMode, maximumBytes: 32),
        let mode = MCPServiceExposureMode(rawValue: rawMode)
      else { return }
      if clientID == MCPClientID.qwenStudio.rawValue {
        model.setQwenStudioExposureMode(mode)
      } else if clientID == MCPClientID.chatGPT.rawValue {
        model.setExposureMode(mode)
      }
    case .copyMCPClientConfiguration:
      guard connected(model), clientID(payload.clientID) == MCPClientID.qwenStudio.rawValue
      else { return }
      model.copyQwenStudioConfiguration()
    case .copyLocalMCPEndpoint:
      guard connected(model), let endpoint = model.safeLocalMCPDescription else { return }
      let pasteboard = NSPasteboard.general
      pasteboard.clearContents()
      pasteboard.setString(endpoint, forType: .string)
      model.postToast("已复制本地 MCP Endpoint", symbol: "doc.on.doc")
    case .rotateMCPClientCredential:
      guard connected(model), clientID(payload.clientID) == MCPClientID.qwenStudio.rawValue
      else { return }
      model.rotateQwenStudioCredential()
    case .saveDeepSeekHarnessMCPServer:
      saveDeepSeekHarnessMCPServer(payload, model: model)
    case .deleteDeepSeekHarnessMCPServer:
      guard connected(model), let id = validatedID(payload.mcpServerID, maximumBytes: 128) else {
        return
      }
      model.deleteDeepSeekHarnessMCPServer(id: id)
    case .setDeepSeekHarnessMCPServerEnabled:
      guard connected(model), let id = validatedID(payload.mcpServerID, maximumBytes: 128),
        let enabled = payload.enabled
      else { return }
      model.setDeepSeekHarnessMCPServerEnabled(id: id, enabled: enabled)
    case .rotateLocalMCPEndpoint:
      guard connected(model) else { return }
      model.rotateLocalMCPEndpoint()
    case .configureTunnel:
      configureTunnel(payload, model: model)
    case .connectTunnel:
      guard connected(model), tunnel(model)?.helperAvailable == true else { return }
      model.connectTunnel()
    case .disconnectTunnel:
      guard connected(model), tunnel(model)?.enabled == true else { return }
      model.disconnectTunnel()
    case .clearTunnel:
      guard connected(model), tunnel(model)?.configured == true else { return }
      model.clearTunnel()
    case .connectAgent:
      connectAgent(payload, model: model)
    case .registerAgent:
      registerAgent(payload, model: model)
    case .beginAgentRegistration:
      beginAgentRegistration(payload, model: model)
    case .selectAgent:
      return
    case .setAgentEnabled:
      guard connected(model), let installation = installation(payload, model: model),
        let enabled = payload.enabled
      else { return }
      model.setAgentInstallationEnabled(installation.installationID, enabled: enabled)
    case .reprobeAgent:
      guard connected(model), let installation = installation(payload, model: model) else { return }
      model.reprobeAgentInstallation(
        installation.installationID,
        acceptReplacement: payload.acceptReplacement ?? false
      )
    case .removeAgent:
      guard connected(model), let installation = installation(payload, model: model) else { return }
      model.removeAgentInstallation(installation.installationID)
    case .refreshAgentModels:
      refreshAgentModels(payload, model: model)
    default:
      return
    }
  }

  private static func clientID(_ value: String?) -> String? {
    guard let value = validatedID(value, maximumBytes: 128),
      value == MCPClientID.chatGPT.rawValue || value == MCPClientID.qwenStudio.rawValue
    else { return nil }
    return value
  }

  private static func tunnel(_ model: BridgeServiceAppModel) -> IPCTunnelStatus? {
    model.serviceStatus?.tunnel
  }

  private static func configureTunnel(
    _ payload: BridgeDesktopCommandPayload,
    model: BridgeServiceAppModel
  ) {
    guard connected(model), tunnel(model)?.helperAvailable == true,
      let tunnelID = validatedID(payload.tunnelID, maximumBytes: 256),
      let runtimeKey = validatedText(payload.runtimeKey, maximumBytes: 8 * 1_024),
      !runtimeKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return }
    model.configureTunnel(tunnelID: tunnelID, runtimeKey: runtimeKey)
  }

  private static func saveDeepSeekHarnessMCPServer(
    _ payload: BridgeDesktopCommandPayload,
    model: BridgeServiceAppModel
  ) {
    guard connected(model), let name = validatedID(payload.name, maximumBytes: 256),
      let transport = validatedID(payload.mcpTransport, maximumBytes: 16),
      transport == "stdio" || transport == "http"
    else { return }
    let command = payload.mcpCommand.flatMap { validatedText($0, maximumBytes: 8 * 1_024) }
    let url = payload.mcpURL.flatMap { validatedText($0, maximumBytes: 4 * 1_024) }
    if transport == "stdio" && (command?.isEmpty != false || url != nil) { return }
    if transport == "http" && (url?.isEmpty != false || command != nil) { return }
    let environment = payload.mcpEnvironmentSecrets ?? []
    let headers = payload.mcpHeaderSecrets ?? []
    guard environment.allSatisfy({ validSecret($0) }), headers.allSatisfy({ validSecret($0) })
    else { return }
    model.saveDeepSeekHarnessMCPServer(
      id: validatedID(payload.mcpServerID, maximumBytes: 128),
      name: name,
      transport: transport,
      command: transport == "stdio" ? command : nil,
      arguments: transport == "stdio" ? payload.arguments ?? [] : [],
      url: transport == "http" ? url : nil,
      environment: environment,
      headers: headers
    )
  }

  private static func validSecret(_ input: BridgeDesktopSecretInput) -> Bool {
    guard let name = validatedID(input.name, maximumBytes: 256) else { return false }
    guard let value = input.value else { return true }
    return validatedText(value, maximumBytes: 16 * 1_024) != nil && !name.isEmpty
  }

  private static func registerAgent(
    _ payload: BridgeDesktopCommandPayload,
    model: BridgeServiceAppModel
  ) {
    guard connected(model), let providerID = validatedID(payload.providerID, maximumBytes: 128),
      model.agentProviders.contains(where: { $0.providerID == providerID }),
      let displayName = validatedID(payload.displayName, maximumBytes: 256),
      let executableURL = panelURL(payload.executable ?? payload.path)
    else { return }
    let configurationURL = payload.configurationPath.flatMap { panelURL($0) }
    model.registerAgentInstallation(
      providerID: providerID,
      displayName: displayName,
      executableURL: executableURL,
      configurationURL: configurationURL
    )
  }

  private static func connectAgent(
    _ payload: BridgeDesktopCommandPayload,
    model: BridgeServiceAppModel
  ) {
    guard connected(model), let providerID = validatedID(payload.providerID, maximumBytes: 128),
      let provider = model.agentProviders.first(where: { $0.providerID == providerID })
    else { return }
    let baseURL = AgentConnectionInput.baseURL(payload.baseURL)
    let apiKey = AgentConnectionInput.apiKey(payload.apiKey)
    let hasExistingInstallation = model.agentInstallations.contains {
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
      model.errorMessage = "请填写 \(provider.displayName) 的 Base URL 和 API key。"
      return
    }
    model.connectAgentInstallation(
      providerID: providerID,
      baseURL: baseURL,
      apiKey: apiKey,
      alwaysProceedConfirmed: payload.confirmed == true
    )
  }

  private static func installation(
    _ payload: BridgeDesktopCommandPayload,
    model: BridgeServiceAppModel
  ) -> IPCAgentInstallationSummary? {
    guard let installationID = validatedID(payload.installationID, maximumBytes: 256) else {
      return nil
    }
    return model.agentInstallations.first { $0.installationID == installationID }
  }

  private static func refreshAgentModels(
    _ payload: BridgeDesktopCommandPayload,
    model: BridgeServiceAppModel
  ) {
    guard connected(model), let providerID = validatedID(payload.providerID, maximumBytes: 128),
      let provider = model.agentProviders.first(where: { $0.providerID == providerID }),
      provider.supportsModelSelection
    else { return }
    let installationID = validatedID(payload.installationID, maximumBytes: 256)
    if let installationID,
      !model.agentInstallations.contains(where: {
        $0.installationID == installationID
          && $0.providerID == providerID
      })
    {
      return
    }
    model.refreshAgentModelCatalog(installationID: installationID, providerID: providerID)
  }

  private static func beginAgentRegistration(
    _ payload: BridgeDesktopCommandPayload,
    model: BridgeServiceAppModel
  ) {
    guard connected(model) else { return }
    let targetProvider: IPCAgentProviderSummary? = {
      if let providerID = validatedID(payload.providerID, maximumBytes: 128) {
        return model.agentProviders.first(where: { $0.providerID == providerID })
      }
      return model.agentProviders.first
    }()
    guard let provider = targetProvider else { return }
    let panel = NSOpenPanel()
    panel.title = "选择 \(provider.displayName) 可执行文件"
    panel.prompt = provider.requiresConfiguration ? "下一步" : "登记并 Probe"
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.resolvesAliases = true
    guard panel.runModal() == .OK, let url = panel.url else { return }
    let configurationURL: URL?
    if provider.requiresConfiguration {
      let configurationPanel = NSOpenPanel()
      configurationPanel.title = "选择 \(provider.displayName) 配置文件"
      configurationPanel.prompt = "登记并 Probe"
      configurationPanel.canChooseFiles = true
      configurationPanel.canChooseDirectories = false
      configurationPanel.allowsMultipleSelection = false
      configurationPanel.resolvesAliases = true
      guard configurationPanel.runModal() == .OK, let selected = configurationPanel.url else {
        return
      }
      configurationURL = selected
    } else {
      configurationURL = nil
    }
    model.registerAgentInstallation(
      providerID: provider.providerID,
      displayName: provider.displayName,
      executableURL: url,
      configurationURL: configurationURL
    )
  }
}
