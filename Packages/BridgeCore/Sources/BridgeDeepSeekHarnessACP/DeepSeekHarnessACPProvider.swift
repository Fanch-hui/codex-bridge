import BridgeACP
import BridgeAgentCore
import Foundation

public struct DeepSeekHarnessACPProviderConfiguration: Sendable {
  public typealias EnvironmentProvider =
    @Sendable (AgentInstallation) async throws -> [String: String]

  public let clientInfo: DeepSeekHarnessACPClientInfo
  public let launchBuilder: DeepSeekHarnessACPLaunchBuilder
  public let requestTimeout: Duration
  public let inactivityTimeout: Duration
  public let eventBufferLimit: Int
  public let runtimeBaseDirectory: String
  public let sourceEnvironment: [String: String]
  public let environmentProvider: EnvironmentProvider
  public let transportFactory: DeepSeekHarnessACPTransportFactory

  public init(
    clientInfo: DeepSeekHarnessACPClientInfo = .init(
      name: "codex-bridge",
      title: "Codex Bridge",
      version: "1"
    ),
    launchBuilder: DeepSeekHarnessACPLaunchBuilder? = nil,
    requestTimeout: Duration = DeepSeekHarnessACPConstants.requestTimeout,
    inactivityTimeout: Duration = DeepSeekHarnessACPConstants.inactivityTimeout,
    eventBufferLimit: Int = DeepSeekHarnessACPConstants.maximumEventBuffer,
    runtimeBaseDirectory: String = FileManager.default.temporaryDirectory
      .appendingPathComponent("CodexBridge/DeepSeekHarnessACP", isDirectory: true).path,
    sourceEnvironment: [String: String] = ProcessInfo.processInfo.environment,
    environmentProvider: EnvironmentProvider? = nil,
    transportFactory: @escaping DeepSeekHarnessACPTransportFactory = { launch in
      try ACPProcessTransport.launch(configuration: launch.process)
    }
  ) throws {
    self.clientInfo = clientInfo
    self.launchBuilder = try launchBuilder ?? DeepSeekHarnessACPLaunchBuilder()
    self.requestTimeout = requestTimeout
    self.inactivityTimeout = inactivityTimeout
    self.eventBufferLimit = max(1, eventBufferLimit)
    self.runtimeBaseDirectory = runtimeBaseDirectory
    self.sourceEnvironment = sourceEnvironment
    self.environmentProvider =
      environmentProvider ?? { _ in
        var environment = sourceEnvironment
        for key in Array(environment.keys)
        where key.caseInsensitiveCompare("DEEPSEEK_API_KEY") == .orderedSame {
          environment.removeValue(forKey: key)
        }
        return environment
      }
    self.transportFactory = transportFactory
  }

  func runtimeEnvironment(for installation: AgentInstallation) async throws -> [String: String] {
    try await environmentProvider(installation)
  }
}

public struct DeepSeekHarnessACPProvider: AgentProvider, Sendable {
  public let descriptor: AgentProviderDescriptor

  let configuration: DeepSeekHarnessACPProviderConfiguration

  public init(configuration: DeepSeekHarnessACPProviderConfiguration? = nil) throws {
    self.configuration = try configuration ?? DeepSeekHarnessACPProviderConfiguration()
    descriptor = try AgentProviderDescriptor(
      providerID: .deepSeekHarness,
      displayName: "DeepSeek Harness",
      adapterRevision: 7
    )
  }

  func makeClient(transport: any ACPTransport) -> DeepSeekHarnessACPClient {
    DeepSeekHarnessACPClient(
      transport: transport,
      clientInfo: configuration.clientInfo,
      requestTimeout: configuration.requestTimeout,
      eventBufferLimit: configuration.eventBufferLimit
    )
  }

  func validate(_ initialization: DeepSeekHarnessACPInitialization) throws {
    guard initialization.protocolVersion == DeepSeekHarnessACPConstants.acpProtocolVersion else {
      throw AgentRuntimeError.unsupportedProtocol(String(initialization.protocolVersion))
    }
    guard initialization.agentName != nil || initialization.agentVersion != nil else { return }
    guard initialization.agentName == DeepSeekHarnessACPConstants.agentName
    else {
      throw AgentRuntimeError.unsupportedProtocol("unexpected_deepseek_harness_identity")
    }
  }
}
