import BridgeMCP
import Foundation

extension ServiceComposition {
  public func refreshMCPInstructions() async {
    for clientID: MCPClientID in [.chatGPT, .qwenStudio, .gemini] {
      await mcpServer?.terminateSessions(for: clientID)
    }
  }

  public func mcpClientStatuses() async throws -> [ServiceMCPClientStatus] {
    let profiles = try await mcpClients.profiles()
    var statuses: [ServiceMCPClientStatus] = []
    for profile in profiles {
      statuses.append(
        ServiceMCPClientStatus(
          profile: profile,
          activeSessionCount: await mcpServer?.activeSessionCount(for: profile.clientID) ?? 0,
          lastConnectedAt: mcpClients.authenticator.lastAuthenticationDate(for: profile.clientID)
        )
      )
    }
    return statuses
  }

  public func setMCPClientEnabled(_ enabled: Bool, for clientID: MCPClientID) async throws {
    do {
      try await mcpClients.setEnabled(enabled, for: clientID)
    } catch {
      await mcpServer?.terminateSessions(for: clientID)
      if clientID == .gemini { await geminiCloud.synchronize(endpoint: endpoint()?.localURL) }
      throw error
    }
    await mcpServer?.terminateSessions(for: clientID)
    if clientID == .gemini {
      await geminiCloud.synchronize(endpoint: endpoint()?.localURL)
    }
  }

  public func setMCPClientExposureMode(
    _ mode: MCPServiceExposureMode,
    for clientID: MCPClientID
  ) async throws {
    try await mcpClients.setExposureMode(mode, for: clientID)
    await mcpServer?.terminateSessions(for: clientID)
  }

  public func rotateMCPClientCredential(for clientID: MCPClientID) async throws {
    do {
      try await mcpClients.rotateCredential(for: clientID)
    } catch {
      await mcpServer?.terminateSessions(for: clientID)
      if clientID == .gemini { await geminiCloud.synchronize(endpoint: endpoint()?.localURL) }
      throw error
    }
    await mcpServer?.terminateSessions(for: clientID)
    if clientID == .gemini {
      await geminiCloud.synchronize(endpoint: endpoint()?.localURL)
    }
  }

  public func setQwenStudioEnabled(_ enabled: Bool) async throws {
    try await setMCPClientEnabled(enabled, for: .qwenStudio)
  }

  public func setQwenStudioExposureMode(_ mode: MCPServiceExposureMode) async throws {
    try await setMCPClientExposureMode(mode, for: .qwenStudio)
  }

  public func rotateQwenStudioCredential() async throws {
    try await rotateMCPClientCredential(for: .qwenStudio)
  }

  public func localMCPConnection(clientID: MCPClientID) async throws -> (url: URL, token: String) {
    guard clientID == .qwenStudio || clientID == .gemini else {
      throw ServiceMCPClientRegistryError.unsupportedClient
    }
    let endpoint = try await startLocalMCP()
    let token = try await mcpClients.credential(for: clientID)
    return (url: endpoint.localURL, token: token)
  }

  public func exportQwenStudioConfiguration() async throws -> String {
    let connection = try await localMCPConnection(clientID: .qwenStudio)
    let configuration: [String: Any] = [
      "mcpServers": [
        "Codex Bridge": [
          "type": "streamable-http",
          "url": connection.url.absoluteString,
          "headers": [MCPHTTPConfiguration.tunnelAuthenticationHeader: connection.token],
        ]
      ]
    ]
    let data = try JSONSerialization.data(
      withJSONObject: configuration, options: [.prettyPrinted, .sortedKeys])
    guard let value = String(data: data, encoding: .utf8) else {
      throw ServiceMCPClientRegistryError.unsupportedClient
    }
    return value
  }
}
