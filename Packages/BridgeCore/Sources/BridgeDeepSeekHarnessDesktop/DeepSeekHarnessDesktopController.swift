import BridgeACP
import BridgeAgentCore
import Foundation

public actor DeepSeekHarnessDesktopController: DeepSeekHarnessDesktopControlling {
  let configuration: DeepSeekHarnessDesktopConfiguration
  private var clients: [AgentInstallationID: DeepSeekHarnessDesktopClient] = [:]
  private var pendingPairing: [AgentInstallationID: DeepSeekHarnessDesktopTrust] = [:]
  private var pendingPairingCode: [AgentInstallationID: String] = [:]

  public init(configuration: DeepSeekHarnessDesktopConfiguration) {
    self.configuration = configuration
  }

  func client(
    _ installation: AgentInstallation, profileID: String? = nil, allowUnpaired: Bool = false,
    replaceTrust: Bool = false
  )
    async throws -> DeepSeekHarnessDesktopClient
  {
    let descriptor = try configuration.descriptorProvider(
      configuration.descriptorPathProvider(installation.id), installation)
    if let profileID, profileID != descriptor.profileID { throw AgentRuntimeError.sessionMismatch }
    var trust = try await configuration.trustProvider(installation.id)
    if replaceTrust { trust = nil }
    if allowUnpaired, let pending = pendingPairing[installation.id],
      pending.profileID == descriptor.profileID, pending.publicKey == descriptor.publicKey
    {
      trust = pending
    }
    if let trust,
      trust.profileID != descriptor.profileID || trust.publicKey != descriptor.publicKey
    {
      throw AgentRuntimeError.unsupportedProtocol("dsh_desktop_profile_changed")
    }
    guard allowUnpaired || trust != nil else {
      throw DeepSeekHarnessDesktopRPCError(
        code: "desktop_pairing_required",
        message: "请先在 DSH 桌面插件中确认 Bridge 配对。")
    }
    if let cached = clients[installation.id], cached.descriptor == descriptor, await cached.isOpen {
      return cached
    }
    if let old = clients.removeValue(forKey: installation.id) { await old.close() }
    let client = try await DeepSeekHarnessDesktopClient.connect(
      descriptor: descriptor, identity: configuration.identityProvider(), trust: trust,
      timeout: configuration.requestTimeout, transportFactory: configuration.transportFactory)
    clients[installation.id] = client
    return client
  }

  func reset(_ installation: AgentInstallation) async {
    if let old = clients.removeValue(forKey: installation.id) { await old.close() }
  }

  func authorizeProject(_ path: String, client: DeepSeekHarnessDesktopClient) async throws {
    let projects = try await configuration.registeredProjectPaths()
    guard
      projects.contains(where: {
        AgentPathSemantics.isContained(path, in: $0) && AgentPathSemantics.isContained($0, in: path)
      })
    else { throw AgentRuntimeError.invalidRequest("dsh.desktop.project") }
    _ = try await client.call(
      "project/sync",
      params: [
        "projectPaths": .array(projects.map(ACPJSONValue.string))
      ])
  }

  public func status(installation: AgentInstallation) async throws -> DeepSeekHarnessDesktopStatus {
    do {
      let client = try await client(installation, allowUnpaired: true)
      let value = try await client.call("pairing/state")
      let candidate = DeepSeekHarnessDesktopTrust(
        profileID: client.descriptor.profileID,
        publicKey: client.descriptor.publicKey)
      if value["paired"]?.boolValue == true, pendingPairing[installation.id] == candidate {
        try await configuration.saveTrust(installation.id, candidate)
        pendingPairing.removeValue(forKey: installation.id)
        pendingPairingCode.removeValue(forKey: installation.id)
      }
      let trusted = try await configuration.trustProvider(installation.id)
      return state(
        value, descriptor: client.descriptor, trusted: trusted == candidate,
        pairingCode: pendingPairingCode[installation.id])
    } catch {
      let trust = try await configuration.trustProvider(installation.id)
      return DeepSeekHarnessDesktopStatus(
        connected: false, paired: trust != nil,
        profileID: trust?.profileID,
        unavailableReason: "DSH Desktop Connector 未连接：\(error.localizedDescription)")
    }
  }

  public func pair(installation: AgentInstallation) async throws -> DeepSeekHarnessDesktopStatus {
    let client = try await client(installation, allowUnpaired: true, replaceTrust: true)
    let candidate = DeepSeekHarnessDesktopTrust(
      profileID: client.descriptor.profileID,
      publicKey: client.descriptor.publicKey)
    pendingPairing[installation.id] = candidate
    let value = try await client.call("pairing/request")
    pendingPairingCode[installation.id] =
      value["pairingCode"]?.stringValue ?? value["code"]?.stringValue
    let status = state(value, descriptor: client.descriptor)
    if status.paired {
      try await configuration.saveTrust(installation.id, candidate)
      pendingPairing.removeValue(forKey: installation.id)
      pendingPairingCode.removeValue(forKey: installation.id)
    }
    return status
  }

  public func revoke(installation: AgentInstallation) async throws {
    let client = try await client(installation)
    _ = try await client.call("pairing/revoke")
    try await configuration.saveTrust(installation.id, nil)
    pendingPairing.removeValue(forKey: installation.id)
    pendingPairingCode.removeValue(forKey: installation.id)
    await reset(installation)
  }

  public func openSession(sessionID: String, projectRoot: String, installation: AgentInstallation)
    async throws
  {
    let client = try await client(installation)
    try await authorizeProject(projectRoot, client: client)
    _ = try await client.call(
      "session/open",
      params: [
        "sessionID": .string(sessionID), "projectPath": .string(projectRoot),
      ])
  }

  public func defaults(installation: AgentInstallation) async throws
    -> DeepSeekHarnessDesktopDefaults
  {
    let client = try await client(installation)
    return defaultsValue(try await client.call("models/defaults"))
  }

  public func setDefaults(modelID: String?, effort: String?, installation: AgentInstallation)
    async throws -> DeepSeekHarnessDesktopDefaults
  {
    let client = try await client(installation)
    let effectiveModelID: String
    if let modelID {
      effectiveModelID = modelID
    } else {
      let current = try await client.call("models/defaults")
      guard let saved = current["modelID"]?.stringValue else {
        throw AgentRuntimeError.invalidRequest("dsh.desktop.defaultModelUnavailable")
      }
      effectiveModelID = saved
    }
    var params: [String: ACPJSONValue] = ["modelID": .string(effectiveModelID)]
    if let effort { params["effort"] = .string(effort) }
    let result = try await client.call(
      "models/set-defaults",
      params: params)
    let saved = defaultsValue(result)
    guard saved.modelID == effectiveModelID, effort.map({ saved.effort == $0 }) ?? true else {
      throw DeepSeekHarnessDesktopRPCError(
        code: "desktop_defaults_not_saved",
        message: "DSH 桌面默认模型保存结果与所选值不一致。")
    }
    return saved
  }

  public func installConnector(installation: AgentInstallation) async throws
    -> DeepSeekHarnessDesktopStatus
  {
    try await configuration.installConnector(installation)
  }

  public func shutdown() async {
    let values = Array(clients.values)
    clients.removeAll()
    pendingPairing.removeAll()
    pendingPairingCode.removeAll()
    for client in values { await client.close() }
  }

  private func state(
    _ value: ACPJSONValue, descriptor: DeepSeekHarnessDesktopDescriptor,
    trusted: Bool = true, pairingCode: String? = nil
  )
    -> DeepSeekHarnessDesktopStatus
  {
    DeepSeekHarnessDesktopStatus(
      connected: true, paired: trusted && value["paired"]?.boolValue == true,
      profileID: descriptor.profileID, instanceID: descriptor.instanceID,
      pairingCode: value["pairingCode"]?.stringValue ?? value["code"]?.stringValue ?? pairingCode,
      protocolRevision: descriptor.protocol,
      unavailableReason: value["unavailableReason"]?.stringValue)
  }

  private func defaultsValue(_ value: ACPJSONValue) -> DeepSeekHarnessDesktopDefaults {
    .init(modelID: value["modelID"]?.stringValue, effort: value["effort"]?.stringValue)
  }
}
