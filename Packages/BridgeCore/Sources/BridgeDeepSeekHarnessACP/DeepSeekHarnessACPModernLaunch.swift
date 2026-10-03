import BridgeAgentCore
import Foundation

#if !os(Windows)
  #if canImport(Darwin)
    import Darwin
  #elseif canImport(Glibc)
    import Glibc
  #endif
#endif

enum DeepSeekHarnessACPModernLaunch {
  private static let packageName = "@deepseek-ai/dsh"

  static func isModernEntry(_ executablePath: String) -> Bool {
    let executable = URL(fileURLWithPath: executablePath).standardizedFileURL
    guard executable.lastPathComponent == "bin.js",
      executable.deletingLastPathComponent().lastPathComponent == "lib"
    else {
      return false
    }
    let packageManifest =
      executable
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("package.json")
    guard
      let data = try? DeepSeekHarnessACPArtifactRuntime.boundedData(
        at: packageManifest.path, maximumBytes: 128 * 1_024, field: "entry_manifest.size"
      ),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      object["name"] as? String == packageName
    else {
      return false
    }
    return true
  }

  static func preparePatch(
    configurationData: Data,
    template: Data,
    runDirectory: String,
    modelID: String?,
    catalogModelIDs: [String]? = nil,
    reasoningEffort: String?,
    mutationIntent: AgentMutationIntent,
    sourceEnvironment: [String: String] = [:],
    usesMessagesProvider: Bool = false
  ) throws -> String {
    let sourceProfile = try DeepSeekHarnessACPModelCatalog.profile(
      configuration: configurationData,
      template: template
    )
    let rawRequested = modelID.flatMap { DeepSeekHarnessACPModelRoutes.decode($0)?.model ?? $0 }
    let selection = try DeepSeekHarnessACPModelCatalog.resolvedSelection(
      configuration: configurationData, template: template,
      modelID: rawRequested, reasoningEffort: usesMessagesProvider ? nil : reasoningEffort
    )
    var modelIDs = catalogModelIDs ?? sourceProfile.modelIDs
    if catalogModelIDs == nil, let rawRequested, !modelIDs.contains(rawRequested) {
      modelIDs.append(rawRequested)
    }
    let selected =
      rawRequested.flatMap { modelIDs.contains($0) ? $0 : nil } ?? modelIDs.first
      ?? selection.modelID
    let routeSelection = modelID.flatMap { DeepSeekHarnessACPModelRoutes.decode($0) }
    let selectedID =
      routeSelection.map { route in
        String(data: try! JSONEncoder().encode([route.provider, selected]), encoding: .utf8)!
      } ?? selected
    let endpoints = try DeepSeekHarnessACPEndpoints.resolve(
      environment: sourceEnvironment, usesMessagesProvider: usesMessagesProvider)

    var patch = makePatch(
      modelIDs: modelIDs,
      selectedModelID: selectedID,
      reasoningEffort: selection.reasoningEffort,
      thinkingEnabled: sourceProfile.supportedReasoningEfforts != ["off"],
      mutationIntent: mutationIntent, endpoints: endpoints,
      usesMessagesProvider: usesMessagesProvider
    )
    let additional = try DeepSeekHarnessACPModelCatalog.additionalEntries(
      configuration: configurationData, template: template
    )
    if !additional.isEmpty {
      patch +=
        "\n- insert:\n"
        + additional.split(separator: "\n", omittingEmptySubsequences: false)
        .map { "    " + $0 }.joined(separator: "\n") + "\n"
    }
    let profile = try DeepSeekHarnessACPPathSupport.append(
      "modern-profile",
      to: runDirectory,
      isDirectory: true
    )
    try DeepSeekHarnessACPPathSupport.createPrivateDirectory(profile)
    let path = try DeepSeekHarnessACPPathSupport.append("acp.patch.yml", to: profile)
    do {
      try Data(patch.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
      #if !os(Windows)
        guard chmod(path, 0o600) == 0 else {
          throw AgentRuntimeError.processUnavailable
        }
      #endif
      return path
    } catch let error as AgentRuntimeError {
      throw error
    } catch {
      throw AgentRuntimeError.processUnavailable
    }
  }

  private static func makePatch(
    modelIDs: [String],
    selectedModelID: String,
    reasoningEffort: String,
    thinkingEnabled: Bool,
    mutationIntent: AgentMutationIntent,
    endpoints: DeepSeekHarnessACPEndpoints, usesMessagesProvider: Bool
  ) -> String {
    let provider = DeepSeekHarnessACPProviderPatch.make(
      modelIDs: modelIDs, selectedModelID: selectedModelID,
      reasoningEffort: reasoningEffort, thinkingEnabled: thinkingEnabled,
      endpoints: endpoints, usesMessagesProvider: usesMessagesProvider)
    let mode = mutationIntent == .workspaceWrite ? "workspace-write" : "read-only"
    return """
      \(provider.configuration)
      - id: acp
        config:
          provider: \(DeepSeekHarnessACPProviderPatch.yamlString(provider.providerID))
          model: \(DeepSeekHarnessACPProviderPatch.yamlString(provider.modelID))
      - id: sandbox-policy
        config:
          mode: \(mode)
          workspaceRoot: !!js process.env.DSH_WORKSPACE_ROOT
      - id: fs-sandbox
        config:
          cwd: !!js process.env.DSH_WORKSPACE_ROOT
      - id: approval
        config:
          policy: ask
      - id: session-persistence-jsonl
        config:
          root: !!js process.env.DSH_SNAPSHOT_SESSIONS_ROOT
      """
  }

}
