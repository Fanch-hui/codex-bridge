import BridgeAgentCore
import BridgeSecurity
import BridgeServiceApplication
import BridgeServiceCore
import BridgeServiceGateway
import BridgeWorkbenchService
import Foundation

enum ServiceProviderGatewayAssembly {
  static func configure(
    gateway: ServiceProviderGateway, mode: ServiceApplicationModeController,
    workbench: ServiceEmbeddedDSHController,
    store: SimpleServiceStore, secrets: any SecretStore, clients: ServiceMCPClientRegistry,
    projects: ServiceProjectService, configuration: ServiceCompositionConfiguration,
    agentRegistry: ServiceAgentRegistry
  ) async throws {
    let editor = ExternalAgentConnection(secrets: secrets) { [weak gateway] input in
      guard let gateway else { throw CancellationError() }
      let resources = try await gateway.resources()
      try resources.validateEntrypoints()
      return try await ExternalAgentConnectionEditor(
        node: resources.node, entry: resources.agentEditorEntry
      ).call(input)
    }
    let authentication = gateway.authentication
    let applications = ServiceExternalApplications(
      store: store, secrets: secrets, mcpClients: clients, projects: projects,
      editor: editor, appExecutable: applicationExecutable(configuration),
      endpoint: { [weak gateway] in
        guard let gateway else { throw CancellationError() }
        return try await gateway.endpointURL()
      },
      modelNames: { [weak gateway] in await gateway?.modelDisplayNames() ?? [:] },
      modelLimits: { [weak gateway] in await gateway?.modelLimits() ?? [:] },
      codexTakeoverCatalog: { [weak gateway] models in
        guard let gateway else { throw CancellationError() }
        return try await gateway.codexTakeoverCatalog(models)
      },
      authorizationChanged: { try authentication.publish($0) })
    let community = ServiceCommunityProviders(
      store: store, secrets: secrets,
      directory: configuration.dataRootURL.appendingPathComponent(
        "CommunityProviders", isDirectory: true),
      resources: { [weak gateway] in
        guard let gateway else { throw CancellationError() }
        return try await gateway.resources()
      },
      antigravityExecutable: { try await antigravityExecutable(in: agentRegistry) })
    await gateway.attach(mode: mode, applications: applications, community: community)
    await workbench.attachCommunityGateway(gateway)
    try await applications.initialize()
    try await gateway.restore()
  }

  /// The community agy plugin must use the CLI the user registered and enabled, so only an
  /// available installation is trusted; an unreviewed or unavailable one is left to the plugin's own search.
  static func antigravityExecutable(in registry: ServiceAgentRegistry) async throws -> String? {
    try await registry.installations(providerID: .antigravity, includeRuntimeArtifacts: false)
      .first(where: \.isSelectable)?.executablePath
  }

  private static func applicationExecutable(_ configuration: ServiceCompositionConfiguration) -> URL
  {
    #if os(macOS)
      if let bundle = configuration.appBundleURL {
        return bundle.appendingPathComponent("Contents/MacOS/CodexBridge")
      }
      return URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    #elseif os(Windows)
      let directory =
        ServiceBundleLocator.currentExecutableURL()?.deletingLastPathComponent()
        ?? Bundle.main.bundleURL
      return directory.appendingPathComponent("codex-bridge-windows-app.exe")
    #else
      return Bundle.main.bundleURL.appendingPathComponent("codex-bridge-linux-app")
    #endif
  }
}
