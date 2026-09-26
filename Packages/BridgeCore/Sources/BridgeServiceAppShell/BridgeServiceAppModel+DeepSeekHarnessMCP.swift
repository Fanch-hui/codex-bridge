import BridgeDesktopUI
import BridgeIPC
import Foundation

extension BridgeServiceAppModel {
  public func saveDeepSeekHarnessMCPServer(
    id: String?,
    name: String,
    transport: String,
    command: String?,
    arguments: [String],
    url: String?,
    environment: [BridgeDesktopSecretInput],
    headers: [BridgeDesktopSecretInput],
    scope: String = BridgeDesktopAgentMCPScope.deepSeekHarness.rawValue
  ) {
    guard scope == selectedAgentMCPScope,
      let scopeValue = BridgeDesktopAgentMCPScope(rawValue: scope)
    else { return }
    let serverID = id ?? UUID().uuidString.lowercased()
    let request = IPCDeepSeekHarnessMCPServerInput(
      id: serverID,
      name: name,
      enabled: deepSeekHarnessMCPServers.first(where: { $0.id == serverID })?.enabled ?? true,
      transport: transport,
      command: command,
      args: arguments,
      url: url,
      environment: environment.map {
        IPCDeepSeekHarnessMCPSecretInput(name: $0.name, value: $0.value)
      },
      headers: headers.map {
        IPCDeepSeekHarnessMCPSecretInput(name: $0.name, value: $0.value)
      },
      scope: scope
    )
    runMutation { [weak self] client in
      _ = try await client.saveDeepSeekHarnessMCPServer(request)
      await self?.refresh(silent: true, includeCatalog: false)
      self?.postToast("\(scopeValue.displayName) MCP 已保存")
    }
  }

  public func setDeepSeekHarnessMCPServerEnabled(
    id: String,
    enabled: Bool,
    scope: String = BridgeDesktopAgentMCPScope.deepSeekHarness.rawValue
  ) {
    guard scope == selectedAgentMCPScope,
      let scopeValue = BridgeDesktopAgentMCPScope(rawValue: scope)
    else { return }
    guard let server = deepSeekHarnessMCPServers.first(where: { $0.id == id }) else { return }
    let request = IPCDeepSeekHarnessMCPServerInput(
      id: server.id,
      name: server.name,
      enabled: enabled,
      transport: server.transport,
      command: server.command,
      args: server.args,
      url: server.url,
      environment: server.environment.map {
        IPCDeepSeekHarnessMCPSecretInput(name: $0.name)
      },
      headers: server.headers.map {
        IPCDeepSeekHarnessMCPSecretInput(name: $0.name)
      },
      scope: scope
    )
    runMutation { [weak self] client in
      _ = try await client.saveDeepSeekHarnessMCPServer(request)
      await self?.refresh(silent: true, includeCatalog: false)
      self?.postToast(
        enabled
          ? "\(scopeValue.displayName) MCP 已启用"
          : "\(scopeValue.displayName) MCP 已停用"
      )
    }
  }

  public func deleteDeepSeekHarnessMCPServer(
    id: String,
    scope: String = BridgeDesktopAgentMCPScope.deepSeekHarness.rawValue
  ) {
    guard scope == selectedAgentMCPScope,
      let scopeValue = BridgeDesktopAgentMCPScope(rawValue: scope)
    else { return }
    guard deepSeekHarnessMCPServers.contains(where: { $0.id == id }) else { return }
    runMutation { [weak self] client in
      try await client.deleteDeepSeekHarnessMCPServer(id: id, scope: scope)
      await self?.refresh(silent: true, includeCatalog: false)
      self?.postToast("\(scopeValue.displayName) MCP 已删除")
    }
  }

  public func setAgentMCPScope(_ scope: String) {
    guard BridgeDesktopAgentMCPScope(rawValue: scope) != nil,
      selectedAgentMCPScope != scope
    else { return }
    selectedAgentMCPScope = scope
    deepSeekHarnessMCPServers = []
    Task { [weak self] in
      await self?.refresh(silent: true, includeCatalog: false)
    }
  }
}
