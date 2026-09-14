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
    reasoningEffort: String?,
    mutationIntent: AgentMutationIntent
  ) throws -> String {
    let sourceProfile = try DeepSeekHarnessACPModelCatalog.profile(
      configuration: configurationData,
      template: template
    )
    let selection = try DeepSeekHarnessACPModelCatalog.resolvedSelection(
      configuration: configurationData,
      template: template,
      modelID: modelID,
      reasoningEffort: reasoningEffort
    )
    var modelIDs = sourceProfile.modelIDs
    if !modelIDs.contains(selection.modelID) {
      modelIDs.append(selection.modelID)
    }

    var patch = makePatch(
      modelIDs: modelIDs,
      selectedModelID: selection.modelID,
      reasoningEffort: selection.reasoningEffort,
      thinkingEnabled: sourceProfile.supportedReasoningEfforts != ["off"],
      mutationIntent: mutationIntent
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
    mutationIntent: AgentMutationIntent
  ) -> String {
    let models = modelIDs.map { "      - id: \(yamlString($0))" }.joined(separator: "\n")
    let mode = mutationIntent == .workspaceWrite ? "workspace-write" : "read-only"
    return """
      # Bridge overlay for the profile-based DSH ACP application.
      - id: llm-deepseek
        config:
          thinking: \(thinkingEnabled ? "enabled" : "disabled")
          reasoningEffort: \(yamlString(reasoningEffort))
          models:
      \(models)
      - id: acp
        config:
          provider: deepseek-official
          model: \(yamlString(selectedModelID))
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
      """
  }

  private static func yamlString(_ value: String) -> String {
    var escaped = value.replacingOccurrences(of: "\\", with: "\\\\")
    escaped = escaped.replacingOccurrences(of: "\"", with: "\\\"")
    return "\"\(escaped)\""
  }
}
