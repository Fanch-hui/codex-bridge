import BridgeAgentCore
import BridgeIPC
import BridgeServiceApplication
import BridgeServiceCore
import Foundation

struct ServiceAgentSetupService: Sendable {
  let paths: ServiceDataPaths
  let registry: ServiceAgentRegistry
  let settings: ServiceSettings
  let application: BridgeServiceApplication
  let discovery: ServiceAgentDiscoveryCatalog
  let bindings: ServiceAgentSetupRuntimeBindings
  let tasks: ServiceTaskManager

  func dependencies() -> ServiceAgentSetupDependencies {
    ServiceAgentSetupDependencies(
      candidates: { try await candidates($0) },
      configure: { try await configure($0, runtime: $1) },
      verify: { try await verify($0, runtime: $1, input: $2) },
      login: { try ServiceAgentSetupLogin.command(request: $0, runtime: $1, paths: paths) })
  }

  func candidates(_ request: IPCAgentSetupRequest) async throws -> [IPCAgentSetupCandidate] {
    let providerID = AgentProviderID(rawValue: request.providerID)
    let distribution = request.qoderDistribution.flatMap(QoderDistribution.init(rawValue:))
    let all = try await registry.installations(providerID: providerID)
    var existing: [ServiceAgentInstallationRecord] = []
    for item in all {
      if let distribution {
        let configured = try await settings.qoderInstallationDistribution(
          installationID: item.id.rawValue)
        let detected = configured ?? QoderDistribution.identify(executablePath: item.executablePath)
        guard detected == distribution else { continue }
      }
      existing.append(item)
    }
    var selectedID = request.installationID
    if selectedID == nil, let distribution {
      selectedID = try await settings.qoderRuntimeSettings(distribution: distribution)
        .activeInstallationID
    }
    if let selectedID, let selected = existing.first(where: { $0.id.rawValue == selectedID }) {
      return [Self.candidate(selected)]
    }
    let ready = existing.filter(\.isSelectable)
    if !ready.isEmpty { return ready.map(Self.candidate) }
    let environment = ToolDiscoveryEnvironment.current()
    let summary = try ServiceAgentAutoDiscovery.discoverySummary(
      providerID: providerID, existingInstallations: existing, environment: environment,
      qoderDistribution: distribution)
    if let path = summary.executablePath {
      return [
        IPCAgentSetupCandidate(
          installationID: "discovered", executablePath: path,
          displayName: ServiceAgentProviderPolicyRegistry.displayName(for: providerID))
      ]
    }
    return []
  }

  private static func candidate(_ record: ServiceAgentInstallationRecord) -> IPCAgentSetupCandidate
  {
    IPCAgentSetupCandidate(
      installationID: record.id.rawValue, executablePath: record.executablePath,
      displayName: record.displayName)
  }

  func configure(_ request: IPCAgentSetupRequest, runtime: ServiceAgentSetupRuntime) async throws {
    _ = try await registrationRequests(request, runtime: runtime)
  }

  func registrationRequests(
    _ request: IPCAgentSetupRequest, runtime: ServiceAgentSetupRuntime,
    input: IPCAgentSetupContinueRequest? = nil
  ) async throws -> [ServiceAgentRegistrationRequest] {
    let providerID = AgentProviderID(rawValue: request.providerID)
    var environment = ToolDiscoveryEnvironment.current()
    if let node = runtime.nodeExecutablePath {
      environment["PATH"] = AgentProviderEnvironment.executableSearchPath(
        executablePath: node, source: environment)
    }
    let requests = try ServiceAgentAutoDiscovery.registrationRequests(
      providerID: providerID, dataPaths: paths,
      existingInstallations: try await registry.installations(providerID: providerID),
      credentialsProvided: input?.baseURL != nil || input?.apiKey != nil,
      environment: environment,
      discoveredExecutablePath: runtime.executablePath,
      qoderDistribution: request.qoderDistribution.flatMap(QoderDistribution.init(rawValue:)))
    return try requests.filter { Self.matchesExecutable($0.executablePath, runtime.executablePath) }
      .map { candidate in
        guard providerID == .pi, let node = runtime.nodeExecutablePath else { return candidate }
        return try ServiceAgentRegistrationRequest(
          providerID: candidate.providerID, displayName: candidate.displayName,
          executablePath: candidate.executablePath, trustProfile: candidate.trustProfile,
          securityProfileID: candidate.securityProfileID, enableOnSuccess: false,
          artifacts: [ServiceAgentInstallationArtifactRequest(role: .nodeInterpreter, path: node)])
      }
  }

  static func matchesExecutable(_ first: String, _ second: String) -> Bool {
    let firstPath = URL(fileURLWithPath: first).resolvingSymlinksInPath().path
    let secondPath = URL(fileURLWithPath: second).resolvingSymlinksInPath().path
    return AgentPathSemantics.relativePath(firstPath, from: secondPath) == ""
  }
}
