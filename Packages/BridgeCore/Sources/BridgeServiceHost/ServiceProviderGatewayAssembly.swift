import BridgeSecurity
import BridgeServiceCore
import Foundation

enum ServiceProviderGatewayAssembly {
  static func configure(
    gateway: ServiceProviderGateway, mode: ServiceApplicationModeController,
    store: SimpleServiceStore, secrets: any SecretStore, clients: ServiceMCPClientRegistry,
    projects: ServiceProjectService, configuration: ServiceCompositionConfiguration
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
      authorizationChanged: { try authentication.publish($0) })
    let community = ServiceCommunityProviders(
      store: store, secrets: secrets,
      directory: configuration.dataRootURL.appendingPathComponent(
        "CommunityProviders", isDirectory: true),
      resources: { [weak gateway] in
        guard let gateway else { throw CancellationError() }
        return try await gateway.resources()
      })
    await gateway.attach(mode: mode, applications: applications, community: community)
    await gateway.existing.workbench?.attachCommunityGateway(gateway)
    try await applications.initialize()
    try await gateway.restore()
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
