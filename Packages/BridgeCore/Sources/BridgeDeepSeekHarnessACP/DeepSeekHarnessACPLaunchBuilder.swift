import BridgeACP
import BridgeAgentCore
import Foundation

#if !os(Windows)
  #if canImport(Darwin)
    import Darwin
  #elseif canImport(Glibc)
    import Glibc
  #endif
#endif

public struct DeepSeekHarnessACPLaunchBuilder: Sendable {
  public let profile: DeepSeekHarnessACPProfile
  public let maximumFrameBytes: Int
  public let maximumStandardErrorBytes: Int
  public let maximumLifetime: Duration

  public init(
    profile: DeepSeekHarnessACPProfile,
    maximumFrameBytes: Int = DeepSeekHarnessACPConstants.maximumFrameBytes,
    maximumStandardErrorBytes: Int = DeepSeekHarnessACPConstants.maximumStandardErrorBytes,
    maximumLifetime: Duration = DeepSeekHarnessACPConstants.maximumProcessLifetime
  ) {
    self.profile = profile
    self.maximumFrameBytes = max(1, maximumFrameBytes)
    self.maximumStandardErrorBytes = max(1, maximumStandardErrorBytes)
    self.maximumLifetime = maximumLifetime
  }

  public init(
    configurationTemplate: Data? = nil,
    maximumFrameBytes: Int = DeepSeekHarnessACPConstants.maximumFrameBytes,
    maximumStandardErrorBytes: Int = DeepSeekHarnessACPConstants.maximumStandardErrorBytes,
    maximumLifetime: Duration = DeepSeekHarnessACPConstants.maximumProcessLifetime
  ) throws {
    try self.init(
      profile: DeepSeekHarnessACPProfile(configurationTemplate: configurationTemplate),
      maximumFrameBytes: maximumFrameBytes,
      maximumStandardErrorBytes: maximumStandardErrorBytes,
      maximumLifetime: maximumLifetime
    )
  }

  public func make(
    installation: AgentInstallation,
    projectRoot: String,
    runDirectory: String,
    persistentStateDirectory: String? = nil,
    modelID: String? = nil,
    catalogModelIDs: [String]? = nil,
    reasoningEffort: String? = nil,
    mutationIntent: AgentMutationIntent = .readOnly,
    networkAllowed _: Bool,
    sourceEnvironment: [String: String] = ProcessInfo.processInfo.environment
  ) throws -> DeepSeekHarnessACPLaunchConfiguration {
    let validated = try profile.validate(installation)
    let project = try DeepSeekHarnessACPPathSupport.canonicalExistingDirectory(
      projectRoot,
      field: "projectRoot"
    )
    let runtime = try DeepSeekHarnessACPPathSupport.preparePrivateDirectory(
      runDirectory,
      field: "runDirectory"
    )
    var environment = try makeEnvironment(
      nodeInterpreter: validated.nodeInterpreterPath,
      projectRoot: project,
      runDirectory: runtime,
      persistentStateDirectory: persistentStateDirectory,
      mutationIntent: mutationIntent,
      sourceEnvironment: sourceEnvironment
    )
    let layout = validated.runtimeLayout
    environment.merge(layout.environment) { _, value in value }
    let modern = layout.isModernProfile
    if modern, sourceEnvironment["DEEPSEEK_BASE_URL"] != nil {
      let endpoints = try DeepSeekHarnessACPEndpoints.resolve(
        environment: sourceEnvironment,
        usesMessagesProvider: layout.usesMessagesProvider)
      environment["DEEPSEEK_BASE_URL"] = endpoints.inferenceBaseURL
      environment["DEEPSEEK_SEARCH_BASE_URL"] = endpoints.searchBaseURL
    }
    guard
      let configurationDirectory = DeepSeekHarnessACPPathSupport.existingParentDirectory(
        of: validated.configurationPath
      )
    else {
      throw AgentRuntimeError.processUnavailable
    }
    let argv: [String]
    if modern {
      let patch = try DeepSeekHarnessACPModernLaunch.preparePatch(
        configurationData: validated.configurationData,
        template: profile.configurationTemplate,
        runDirectory: runtime,
        modelID: modelID,
        catalogModelIDs: catalogModelIDs,
        reasoningEffort: reasoningEffort,
        mutationIntent: mutationIntent,
        sourceEnvironment: sourceEnvironment,
        usesMessagesProvider: layout.usesMessagesProvider
      )
      let bootstrap = try DeepSeekHarnessACPProfileBootstrap.prepare(
        configurationDirectory: configurationDirectory, runDirectory: runtime,
        usesMessagesProvider: layout.usesMessagesProvider)
      argv =
        [layout.runtimePath] + layout.runtimeArguments + [
          "--import", bootstrap,
          layout.entryPath,
          "--profile",
          "acp",
          "--patch",
          patch,
        ]
    } else {
      let configuration = try prepareRuntimeProfile(
        sourceRoot: validated.sourceRoot,
        runDirectory: runtime,
        configurationData: validated.configurationData,
        modelID: modelID,
        reasoningEffort: reasoningEffort,
        mutationIntent: mutationIntent
      )
      argv = [
        validated.nodeInterpreterPath,
        validated.executablePath,
        "--config",
        configuration,
      ]
    }
    return DeepSeekHarnessACPLaunchConfiguration(
      process: ACPProcessTransportConfiguration(
        argv: argv,
        workingDirectory: modern ? runtime : configurationDirectory,
        environment: environment,
        maximumFrameBytes: maximumFrameBytes,
        maximumStandardErrorBytes: maximumStandardErrorBytes,
        maximumLifetime: maximumLifetime,
        inputEOFGracePeriod: .seconds(6)
      ),
      runDirectory: runtime,
      resolvedNodeInterpreterPath: validated.nodeInterpreterPath,
      resolvedExecutablePath: validated.executablePath,
      resolvedConfigurationPath: validated.configurationPath
    )
  }

}
