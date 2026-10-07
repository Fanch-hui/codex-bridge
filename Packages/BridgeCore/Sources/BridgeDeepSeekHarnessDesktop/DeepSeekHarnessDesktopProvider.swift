import BridgeACP
import BridgeAgentCore
import BridgeDeepSeekHarnessACP
import BridgeSecurity
import Foundation

public struct DeepSeekHarnessDesktopProvider: AgentProvider, AgentNativeSessionDirectoryProviding,
  AgentInstallationArtifactProviding, AgentInstallationRuntimeArtifactProviding, Sendable
{
  public let descriptor: AgentProviderDescriptor
  public let controller: DeepSeekHarnessDesktopController
  let configuration: DeepSeekHarnessDesktopConfiguration
  private let runtimeArtifactProvider: any AgentInstallationRuntimeArtifactProviding

  public init(
    configuration: DeepSeekHarnessDesktopConfiguration,
    providerID: AgentProviderID = .deepSeekHarness,
    runtimeArtifactProvider: (any AgentInstallationRuntimeArtifactProviding)? = nil
  ) throws {
    guard providerID == .deepSeekHarness || providerID == .deepSeekHarnessDesktop else {
      throw AgentRuntimeError.providerUnavailable(providerID)
    }
    self.configuration = configuration
    self.runtimeArtifactProvider = try runtimeArtifactProvider ?? DeepSeekHarnessACPProvider()
    controller = DeepSeekHarnessDesktopController(configuration: configuration)
    descriptor = try AgentProviderDescriptor(
      providerID: providerID,
      displayName: "DSH 桌面", adapterRevision: 11)
  }

  public var nativeSessionDirectoryManager: (any AgentNativeSessionDirectoryManaging)? {
    DeepSeekHarnessDesktopSessionDirectory(controller: controller, configuration: configuration)
  }

  public func installationArtifacts(for installation: AgentInstallation) async throws
    -> [AgentInstallationArtifact]
  {
    for artifact in installation.artifacts where artifact.role == .nodeInterpreter {
      let current = try SecureFileArtifactSnapshot.capture(
        at: artifact.canonicalPath, requiresExecutable: true)
      guard current.sha256 == artifact.sha256 else {
        throw AgentRuntimeError.installationUnavailable(installation.id)
      }
    }
    return installation.artifacts
  }

  public func installationRuntimeArtifacts(for installation: AgentInstallation) async throws
    -> [AgentInstallationRuntimeArtifact]
  {
    try await runtimeArtifactProvider.installationRuntimeArtifacts(for: installation)
  }

  static let capabilities: Set<AgentCapability> = [
    .sessionCreate, .sessionContinue, .interrupt, .textDelta, .reasoningDelta, .toolLifecycle,
    .usage, .oneShotApproval, .structuredUserInput, .workspaceRead, .workspaceWriteInPlace,
    .modelSelection, .effortSelection,
  ]

  static var snapshot: AgentCapabilitySnapshot {
    .init(advertised: capabilities, observed: capabilities, enforced: capabilities)
  }

  public func probe(_ request: AgentProbeRequest) async -> AgentProbeResult {
    do {
      let client = try await controller.client(
        request.installation,
        profileID: request.runtimeBinding?.profileID)
      _ = try await client.call("models/list")
      let resolved = try AgentInstallation(
        id: request.installation.id,
        providerID: request.installation.providerID,
        executablePath: request.installation.executablePath,
        version: client.descriptor.desktopVersion, protocolRevision: client.descriptor.protocol,
        artifacts: request.installation.artifacts,
        runtimeArtifacts: request.installation.runtimeArtifacts)
      return AgentProbeResult(
        installation: resolved, available: true,
        capabilities: Self.snapshot)
    } catch {
      return AgentProbeResult(
        installation: request.installation, available: false,
        capabilities: .empty, unavailableReason: error.localizedDescription)
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
    installation: AgentInstallation, projectRoot: String?, selectedModelID: String?,
    runtimeBinding: AgentRuntimeBinding?
  ) async throws -> [AgentModelDescriptor] {
    let client = try await controller.client(installation, profileID: runtimeBinding?.profileID)
    let value = try await client.call("models/list")
    guard let models = value["models"]?.arrayValue else {
      throw AgentRuntimeError.malformedEvent("dsh_desktop_models")
    }
    let defaultID = value["defaults"]?["modelID"]?.stringValue
    return try models.map { model in
      guard let id = model["id"]?.stringValue, id.hasPrefix("dsh-native:"),
        let displayName = model["displayName"]?.stringValue
      else { throw AgentRuntimeError.malformedEvent("dsh_desktop_model") }
      return try AgentModelDescriptor(
        id: id, displayName: displayName,
        supportedReasoningEfforts: model["efforts"]?.arrayValue?.compactMap(\.stringValue) ?? [],
        defaultReasoningEffort: model["defaultEffort"]?.stringValue,
        isDefaultModel: id == defaultID, contextWindowTokens: model["contextWindow"]?.intValue,
        inputModalities: [.text])
    }
  }

  public func start(_ request: AgentExecutionRequest, installation: AgentInstallation) async throws
    -> AgentExecutionHandle
  {
    guard request.mutationIntent != .readOnly else {
      throw AgentRuntimeError.capabilityUnavailable(.readOnlyExecution)
    }
    guard request.attachments.isEmpty, request.selectedSkills.isEmpty else {
      throw AgentRuntimeError.invalidRequest("dsh.desktop.textOnly")
    }
    guard request.workspaceStrategy != .isolatedGitWorktree else {
      throw AgentRuntimeError.capabilityUnavailable(.workspaceWriteIsolated)
    }
    guard let runtime = request.runtimeBinding, runtime.connectionMode == .nativeDesktop,
      runtime.profileID != nil
    else { throw AgentRuntimeError.invalidRequest("dsh.desktop.runtimeBinding") }
    guard Self.capabilities.isSuperset(of: request.requiredCapabilities) else {
      throw AgentRuntimeError.capabilityUnavailable(
        request.requiredCapabilities.subtracting(Self.capabilities).first ?? .readOnlyExecution)
    }
    let client = try await controller.client(installation, profileID: runtime.profileID)
    try await controller.authorizeProject(request.projectRoot, client: client)
    let catalog = try await models(
      installation: installation, projectRoot: request.projectRoot,
      selectedModelID: request.model, runtimeBinding: runtime)
    if let modelID = request.model {
      guard let model = catalog.first(where: { $0.id == modelID }) else {
        throw AgentRuntimeError.modelUnavailable(modelID)
      }
      if let effort = request.effort, !model.supportedReasoningEfforts.contains(effort) {
        throw AgentRuntimeError.invalidRequest("dsh.desktop.effort")
      }
    }
    let execution = DeepSeekHarnessDesktopExecution(
      request: request, installation: installation,
      controller: controller, client: client)
    return try await execution.start()
  }
}
