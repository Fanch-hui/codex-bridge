import AppKit
import BridgeDesktopUI
import BridgeIPC
import BridgeMCP

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
    case .registerAgent:
      registerAgent(payload, model: model)
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
}
