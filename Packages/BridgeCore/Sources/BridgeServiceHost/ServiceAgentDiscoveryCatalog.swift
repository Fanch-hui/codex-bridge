import BridgeAgentCore
import BridgeServiceApplication
import BridgeServiceCore
import Foundation

struct ServiceAgentDiscoverySummary: Codable, Equatable, Sendable {
  let state: String
  let message: String?
  let executablePath: String?
  let configurationPath: String?

  static let notFound = ServiceAgentDiscoverySummary(
    state: "not_found",
    message: "未发现本机可连接的 Agent。",
    executablePath: nil,
    configurationPath: nil
  )
}

/// Shares filesystem discovery until a desktop client explicitly requests a scan.
/// Registration and Probe remain explicit user actions.
actor ServiceAgentDiscoveryCatalog {
  private let environment: [String: String]?
  private let cacheURL: URL?
  private var cached: [AgentProviderID: ServiceAgentDiscoverySummary]?

  init(environment: [String: String]? = nil, cacheURL: URL? = nil) {
    self.environment = environment
    self.cacheURL = cacheURL
    self.cached = cacheURL.flatMap(ServiceAgentDiscoveryCache.load)
  }

  func summaries(
    providerIDs: [AgentProviderID],
    existingInstallations: [ServiceAgentInstallationRecord],
    forceRefresh: Bool = false
  ) -> [AgentProviderID: ServiceAgentDiscoverySummary] {
    if cached == nil || forceRefresh {
      let currentEnvironment = environment ?? ToolDiscoveryEnvironment.current()
      cached = ServiceAgentAutoDiscovery.discoverySummaries(
        providerIDs: providerIDs,
        existingInstallations: existingInstallations,
        environment: currentEnvironment
      )
      if let cached, let cacheURL {
        try? ServiceAgentDiscoveryCache.save(cached, to: cacheURL)
      }
    }
    let values = cached ?? [:]
    return Dictionary(
      uniqueKeysWithValues: providerIDs.map { providerID in
        (providerID, values[providerID] ?? .notFound)
      })
  }
}

extension ServiceAgentAutoDiscovery {
  static func discoverySummaries(
    providerIDs: [AgentProviderID],
    existingInstallations: [ServiceAgentInstallationRecord],
    environment: [String: String]
  ) -> [AgentProviderID: ServiceAgentDiscoverySummary] {
    let recordsByProvider = Dictionary(grouping: existingInstallations, by: \.providerID)
    return Dictionary(
      uniqueKeysWithValues: providerIDs.map { providerID in
        let records = recordsByProvider[providerID] ?? []
        let summary =
          (try? discoverySummary(
            providerID: providerID,
            existingInstallations: records,
            environment: environment
          ))
          ?? ServiceAgentDiscoverySummary(
            state: "failed",
            message: "本机 Agent 索引失败。",
            executablePath: nil,
            configurationPath: nil
          )
        return (providerID, summary)
      })
  }

  static func discoverySummary(
    providerID: AgentProviderID,
    existingInstallations: [ServiceAgentInstallationRecord],
    environment: [String: String]
  ) throws -> ServiceAgentDiscoverySummary {
    switch providerID {
    case .openCode:
      let requests = try commandLineRequests(
        providerID: providerID,
        names: ["opencode", "opencode-cli"],
        displayName: "OpenCode",
        trustProfile: .managed,
        securityProfileID: ServiceAgentProviderPolicyRegistry.controlledReadOnlyProfileID,
        existingPaths: existingInstallations.map(\.executablePath),
        environment: environment
      )
      return discoveredSummary(from: requests)
    case .antigravity:
      let requests = try commandLineRequests(
        providerID: providerID,
        names: ["agy", "antigravity"],
        displayName: "Antigravity",
        trustProfile: .userTrusted,
        securityProfileID: AgentProfileID(rawValue: "desktop-shared"),
        existingPaths: existingInstallations.map(\.executablePath),
        environment: environment
      )
      return discoveredSummary(from: requests)
    case .deepSeekHarness:
      return deepSeekDiscoverySummary(
        existingInstallations: existingInstallations,
        environment: environment
      )
    default:
      return .notFound
    }
  }

  private static func discoveredSummary(
    from requests: [ServiceAgentRegistrationRequest]
  ) -> ServiceAgentDiscoverySummary {
    guard let request = requests.first else { return .notFound }
    return ServiceAgentDiscoverySummary(
      state: "discovered",
      message: nil,
      executablePath: request.executablePath,
      configurationPath: request.configurationPath
    )
  }

  private static func deepSeekDiscoverySummary(
    existingInstallations: [ServiceAgentInstallationRecord],
    environment: [String: String]
  ) -> ServiceAgentDiscoverySummary {
    let executable = deepSeekExecutableCandidates(
      existingInstallations: existingInstallations,
      environment: environment
    )
    .lazy.compactMap(canonicalRegularFile)
    .first(where: { path in
      #if os(Windows)
        return !isWindowsGUIExecutable(path)
      #else
        return true
      #endif
    })
    guard let executable else {
      return ServiceAgentDiscoverySummary(
        state: "not_found",
        message: "未找到已构建的 DSH 安装。请确认构建完成；也可在高级路径登记中选择 apps/cli/lib/bin.js。",
        executablePath: nil,
        configurationPath: nil
      )
    }

    let configuration = deepSeekConfigurationCandidates(
      existingInstallations: existingInstallations,
      environment: environment
    )
    .lazy.compactMap(canonicalRegularFile)
    .first
    return ServiceAgentDiscoverySummary(
      state: "discovered",
      message: configuration == nil ? "已发现 DSH，需要配置 Base URL 与 API key。" : nil,
      executablePath: executable,
      configurationPath: configuration
    )
  }
}
