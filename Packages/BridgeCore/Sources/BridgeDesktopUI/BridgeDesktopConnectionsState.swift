import Foundation

public struct BridgeDesktopTunnelState: Codable, Equatable, Sendable {
  public let configured: Bool
  public let enabled: Bool
  public let helperAvailable: Bool
  public let tunnelID: String?
  public let lifecycle: String
  public let acceptsRemoteSubmissions: Bool
  public let actionRequired: Bool
  public let canConfigure: Bool
  public let canConnect: Bool
  public let canDisconnect: Bool
  public let canClear: Bool

  public init(
    configured: Bool,
    enabled: Bool,
    helperAvailable: Bool,
    tunnelID: String? = nil,
    lifecycle: String,
    acceptsRemoteSubmissions: Bool,
    actionRequired: Bool,
    canConfigure: Bool = true,
    canConnect: Bool = false,
    canDisconnect: Bool = false,
    canClear: Bool = false
  ) {
    self.configured = configured
    self.enabled = enabled
    self.helperAvailable = helperAvailable
    self.tunnelID = tunnelID
    self.lifecycle = lifecycle
    self.acceptsRemoteSubmissions = acceptsRemoteSubmissions
    self.actionRequired = actionRequired
    self.canConfigure = canConfigure
    self.canConnect = canConnect
    self.canDisconnect = canDisconnect
    self.canClear = canClear
  }
}

public struct BridgeDesktopCodexConnectionState: Codable, Equatable, Sendable {
  public let connectionState: String
  public let modelCount: Int
  public let modelError: String?
  public let isRefreshing: Bool
  public let canRefresh: Bool
  public let isConnected: Bool?
  public let executablePath: String?
  public let resolvedExecutablePath: String?
  public let canEditExecutable: Bool

  public init(
    connectionState: String = "unknown",
    modelCount: Int = 0,
    modelError: String? = nil,
    isRefreshing: Bool = false,
    canRefresh: Bool = false,
    isConnected: Bool? = nil,
    executablePath: String? = nil,
    resolvedExecutablePath: String? = nil,
    canEditExecutable: Bool = false
  ) {
    self.connectionState = connectionState
    self.modelCount = modelCount
    self.modelError = modelError
    self.isRefreshing = isRefreshing
    self.canRefresh = canRefresh
    self.isConnected = isConnected
    self.executablePath = executablePath
    self.resolvedExecutablePath = resolvedExecutablePath
    self.canEditExecutable = canEditExecutable
  }
}

public struct BridgeDesktopMCPClientRow: Codable, Equatable, Sendable {
  public let clientID: String
  public let displayName: String
  public let enabled: Bool
  public let exposureMode: String
  public let exposureOptions: [BridgeDesktopChoice]
  public let activeSessionCount: Int
  public let lastConnectedAt: String?
  public let canToggle: Bool
  public let canCopyConfiguration: Bool
  public let canRotateCredential: Bool

  public init(
    clientID: String,
    displayName: String,
    enabled: Bool,
    exposureMode: String,
    exposureOptions: [BridgeDesktopChoice] = [],
    activeSessionCount: Int,
    lastConnectedAt: String? = nil,
    canToggle: Bool = true,
    canCopyConfiguration: Bool = false,
    canRotateCredential: Bool = false
  ) {
    self.clientID = clientID
    self.displayName = displayName
    self.enabled = enabled
    self.exposureMode = exposureMode
    self.exposureOptions = exposureOptions
    self.activeSessionCount = activeSessionCount
    self.lastConnectedAt = lastConnectedAt
    self.canToggle = canToggle
    self.canCopyConfiguration = canCopyConfiguration
    self.canRotateCredential = canRotateCredential
  }
}

public struct BridgeDesktopDeepSeekHarnessMCPRow: Codable, Equatable, Sendable {
  public let id: String
  public let name: String
  public let enabled: Bool
  public let transport: String
  public let command: String?
  public let arguments: [String]
  public let url: String?
  public let environment: [BridgeDesktopSecretSummary]
  public let headers: [BridgeDesktopSecretSummary]
  public let canToggle: Bool
  public let canEdit: Bool
  public let canDelete: Bool

  public init(
    id: String,
    name: String,
    enabled: Bool,
    transport: String,
    command: String? = nil,
    arguments: [String] = [],
    url: String? = nil,
    environment: [BridgeDesktopSecretSummary] = [],
    headers: [BridgeDesktopSecretSummary] = [],
    canToggle: Bool = true,
    canEdit: Bool = true,
    canDelete: Bool = true
  ) {
    self.id = id
    self.name = name
    self.enabled = enabled
    self.transport = transport
    self.command = command
    self.arguments = arguments
    self.url = url
    self.environment = environment
    self.headers = headers
    self.canToggle = canToggle
    self.canEdit = canEdit
    self.canDelete = canDelete
  }
}

public struct BridgeDesktopSecretInput: Codable, Equatable, Sendable {
  public let name: String
  public let value: String?

  public init(name: String, value: String? = nil) {
    self.name = name
    self.value = value
  }
}

public struct BridgeDesktopSecretSummary: Codable, Equatable, Sendable {
  public let name: String
  public let hasValue: Bool

  public init(name: String, hasValue: Bool) {
    self.name = name
    self.hasValue = hasValue
  }
}

public struct BridgeDesktopAgentProviderRow: Codable, Equatable, Sendable {
  public let providerID: String
  public let displayName: String
  public let adapterRevision: Int
  public let discoveryState: String?
  public let discoveryMessage: String?
  public let discoveredExecutablePath: String?
  public let discoveredConfigurationPath: String?
  public let configuredBaseURL: String?
  public let requiresConfiguration: Bool
  public let requiresHeadlessAlwaysProceed: Bool?
  public let supportsModelSelection: Bool
  public let supportsEffortSelection: Bool
  public let supportsSteer: Bool
  public let supportsWorkspaceWrite: Bool
  public let detail: String?

  public init(
    providerID: String,
    displayName: String,
    adapterRevision: Int,
    discoveryState: String? = nil,
    discoveryMessage: String? = nil,
    discoveredExecutablePath: String? = nil,
    discoveredConfigurationPath: String? = nil,
    configuredBaseURL: String? = nil,
    requiresConfiguration: Bool = false,
    requiresHeadlessAlwaysProceed: Bool? = nil,
    supportsModelSelection: Bool = true,
    supportsEffortSelection: Bool = true,
    supportsSteer: Bool = false,
    supportsWorkspaceWrite: Bool = true,
    detail: String? = nil
  ) {
    self.providerID = providerID
    self.displayName = displayName
    self.adapterRevision = adapterRevision
    self.discoveryState = discoveryState
    self.discoveryMessage = discoveryMessage
    self.discoveredExecutablePath = discoveredExecutablePath
    self.discoveredConfigurationPath = discoveredConfigurationPath
    self.configuredBaseURL = configuredBaseURL
    self.requiresConfiguration = requiresConfiguration
    self.requiresHeadlessAlwaysProceed = requiresHeadlessAlwaysProceed
    self.supportsModelSelection = supportsModelSelection
    self.supportsEffortSelection = supportsEffortSelection
    self.supportsSteer = supportsSteer
    self.supportsWorkspaceWrite = supportsWorkspaceWrite
    self.detail = detail
  }
}

public struct BridgeDesktopAgentInstallationRow: Codable, Equatable, Sendable {
  public let installationID: String
  public let providerID: String
  public let displayName: String
  public let executablePath: String
  public let version: String?
  public let protocolRevision: String?
  public let adapterRevision: Int
  public let trustProfile: String
  public let securityProfileID: String?
  public let enabled: Bool
  public let availability: String
  public let effectiveCapabilities: [String]
  public let lastProbeError: String?
  public let lastProbedAt: String?
  public let updatedAt: String
  public let canToggle: Bool
  public let canReprobe: Bool
  public let canRemove: Bool

  public init(
    installationID: String,
    providerID: String,
    displayName: String,
    executablePath: String,
    version: String? = nil,
    protocolRevision: String? = nil,
    adapterRevision: Int,
    trustProfile: String,
    securityProfileID: String? = nil,
    enabled: Bool,
    availability: String,
    effectiveCapabilities: [String] = [],
    lastProbeError: String? = nil,
    lastProbedAt: String? = nil,
    updatedAt: String,
    canToggle: Bool = true,
    canReprobe: Bool = true,
    canRemove: Bool = true
  ) {
    self.installationID = installationID
    self.providerID = providerID
    self.displayName = displayName
    self.executablePath = executablePath
    self.version = version
    self.protocolRevision = protocolRevision
    self.adapterRevision = adapterRevision
    self.trustProfile = trustProfile
    self.securityProfileID = securityProfileID
    self.enabled = enabled
    self.availability = availability
    self.effectiveCapabilities = effectiveCapabilities
    self.lastProbeError = lastProbeError
    self.lastProbedAt = lastProbedAt
    self.updatedAt = updatedAt
    self.canToggle = canToggle
    self.canReprobe = canReprobe
    self.canRemove = canRemove
  }
}

public struct BridgeDesktopConnectionsState: Codable, Equatable, Sendable {
  public let header: BridgeDesktopPageHeader
  public let summaryRows: [BridgeDesktopServiceRow]
  public let localMCPURL: String?
  public let localMCPState: String
  public let canCopyLocalMCPURL: Bool
  public let canRotateLocalMCPEndpoint: Bool
  public let tunnel: BridgeDesktopTunnelState
  public let codex: BridgeDesktopCodexConnectionState?
  public let clients: [BridgeDesktopMCPClientRow]
  public let deepSeekHarnessMCPServers: [BridgeDesktopDeepSeekHarnessMCPRow]
  public let canManageDeepSeekHarnessMCP: Bool
  public let providers: [BridgeDesktopAgentProviderRow]
  public let installations: [BridgeDesktopAgentInstallationRow]
  public let canRegisterAgent: Bool
  public let canScanAgents: Bool?
  public let isManagingAgents: Bool?
  public let agentOperationRevision: Int?
  public let statusMessage: String?

  public init(
    header: BridgeDesktopPageHeader,
    summaryRows: [BridgeDesktopServiceRow] = [],
    localMCPURL: String? = nil,
    localMCPState: String = "unknown",
    canCopyLocalMCPURL: Bool = false,
    canRotateLocalMCPEndpoint: Bool = false,
    tunnel: BridgeDesktopTunnelState,
    codex: BridgeDesktopCodexConnectionState? = nil,
    clients: [BridgeDesktopMCPClientRow] = [],
    deepSeekHarnessMCPServers: [BridgeDesktopDeepSeekHarnessMCPRow] = [],
    canManageDeepSeekHarnessMCP: Bool = false,
    providers: [BridgeDesktopAgentProviderRow] = [],
    installations: [BridgeDesktopAgentInstallationRow] = [],
    canRegisterAgent: Bool = true,
    canScanAgents: Bool? = nil,
    isManagingAgents: Bool? = nil,
    agentOperationRevision: Int? = nil,
    statusMessage: String? = nil
  ) {
    self.header = header
    self.summaryRows = summaryRows
    self.localMCPURL = localMCPURL
    self.localMCPState = localMCPState
    self.canCopyLocalMCPURL = canCopyLocalMCPURL
    self.canRotateLocalMCPEndpoint = canRotateLocalMCPEndpoint
    self.tunnel = tunnel
    self.codex = codex
    self.clients = clients
    self.deepSeekHarnessMCPServers = deepSeekHarnessMCPServers
    self.canManageDeepSeekHarnessMCP = canManageDeepSeekHarnessMCP
    self.providers = providers
    self.installations = installations
    self.canRegisterAgent = canRegisterAgent
    self.canScanAgents = canScanAgents
    self.isManagingAgents = isManagingAgents
    self.agentOperationRevision = agentOperationRevision
    self.statusMessage = statusMessage
  }
}
