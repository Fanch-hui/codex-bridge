import BridgeAgentCore
import Foundation

public struct DeepSeekHarnessProvider: AgentProvider, AgentNativeSessionDirectoryProviding,
  AgentInstallationArtifactProviding, AgentInstallationRuntimeArtifactProviding, Sendable
{
  public let descriptor: AgentProviderDescriptor
  private let acp: any AgentProvider
  private let desktop: DeepSeekHarnessDesktopProvider
  private let modeProvider:
    @Sendable (AgentInstallationID) async throws -> DeepSeekHarnessConnectionMode

  public init(
    acp: any AgentProvider, desktop: DeepSeekHarnessDesktopProvider,
    modeProvider:
      @escaping @Sendable (AgentInstallationID) async throws -> DeepSeekHarnessConnectionMode
  )
    throws
  {
    guard acp.descriptor.providerID == .deepSeekHarness else {
      throw AgentRuntimeError.invalidRequest("dsh.provider")
    }
    self.acp = acp
    self.desktop = desktop
    self.modeProvider = modeProvider
    descriptor = acp.descriptor
  }

  public var nativeSessionDirectoryManager: (any AgentNativeSessionDirectoryManaging)? {
    DeepSeekHarnessDesktopSessionDirectory(
      controller: desktop.controller,
      configuration: desktop.configuration, modeProvider: modeProvider)
  }

  public func installationArtifacts(for installation: AgentInstallation) async throws
    -> [AgentInstallationArtifact]
  {
    if try await modeProvider(installation.id) == .nativeDesktop {
      return try await desktop.installationArtifacts(for: installation)
    }
    if let provider = acp as? any AgentInstallationArtifactProviding {
      return try await provider.installationArtifacts(for: installation)
    }
    return installation.artifacts
  }

  public func installationRuntimeArtifacts(for installation: AgentInstallation) async throws
    -> [AgentInstallationRuntimeArtifact]
  {
    guard let provider = acp as? any AgentInstallationRuntimeArtifactProviding else {
      return installation.runtimeArtifacts
    }
    return try await provider.installationRuntimeArtifacts(for: installation)
  }

  public func probe(_ request: AgentProbeRequest) async -> AgentProbeResult {
    do {
      let provider = try await selected(request.installation, binding: request.runtimeBinding)
      return await provider.probe(request)
    } catch {
      return AgentProbeResult(
        installation: request.installation, available: false,
        capabilities: .empty, unavailableReason: String(describing: error))
    }
  }

  public func models(installation: AgentInstallation, projectRoot: String?) async throws
    -> [AgentModelDescriptor]
  {
    try await models(
      installation: installation, projectRoot: projectRoot, selectedModelID: nil,
      runtimeBinding: nil)
  }

  public func models(
    installation: AgentInstallation, projectRoot: String?, selectedModelID: String?
  )
    async throws -> [AgentModelDescriptor]
  {
    try await models(
      installation: installation, projectRoot: projectRoot, selectedModelID: selectedModelID,
      runtimeBinding: nil)
  }

  public func models(
    installation: AgentInstallation, projectRoot: String?, selectedModelID: String?,
    runtimeBinding: AgentRuntimeBinding?
  ) async throws -> [AgentModelDescriptor] {
    let provider = try await selected(installation, binding: runtimeBinding)
    return try await provider.models(
      installation: installation, projectRoot: projectRoot,
      selectedModelID: selectedModelID, runtimeBinding: runtimeBinding)
  }

  public func start(_ request: AgentExecutionRequest, installation: AgentInstallation) async throws
    -> AgentExecutionHandle
  {
    // Missing bindings belong to tasks created before native desktop support.
    let provider: any AgentProvider =
      request.runtimeBinding?.connectionMode == .nativeDesktop ? desktop : acp
    return try await provider.start(request, installation: installation)
  }

  private func selected(_ installation: AgentInstallation, binding: AgentRuntimeBinding?)
    async throws
    -> any AgentProvider
  {
    let mode: DeepSeekHarnessConnectionMode
    if let binding {
      mode = binding.connectionMode
    } else {
      mode = try await modeProvider(installation.id)
    }
    return mode == .nativeDesktop ? desktop : acp
  }
}
