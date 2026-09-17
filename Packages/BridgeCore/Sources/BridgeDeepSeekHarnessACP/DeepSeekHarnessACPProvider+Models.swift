import BridgeAgentCore
import Foundation

extension DeepSeekHarnessACPProvider {
  public func models(
    installation: AgentInstallation,
    projectRoot: String?,
    selectedModelID: String?
  ) async throws -> [AgentModelDescriptor] {
    guard installation.providerID == .deepSeekHarness else {
      throw AgentRuntimeError.providerUnavailable(installation.providerID)
    }
    let fallback = try configuration.launchBuilder.profile.modelDescriptors(
      for: installation,
      selectedModelID: nil
    )
    let catalogRoot = try makeProbeRoot(projectRoot)
    let runDirectory: String
    do {
      runDirectory = try makeRunDirectory(prefix: "catalog-run")
    } catch {
      cleanup(runDirectory: nil, probeRoot: catalogRoot)
      throw error
    }
    var client: DeepSeekHarnessACPClient?
    do {
      let sourceEnvironment = try await configuration.runtimeEnvironment(for: installation)
      let remoteModels =
        DeepSeekHarnessACPModernLaunch.isModernEntry(installation.executablePath)
        ? try await DeepSeekHarnessACPRemoteModels.fetch(environment: sourceEnvironment) : nil
      let launchModel = remoteModels.flatMap { models in
        selectedModelID.flatMap { models.contains($0) ? $0 : nil } ?? models.first
      }
      let launch = try configuration.launchBuilder.make(
        installation: installation,
        projectRoot: catalogRoot.path,
        runDirectory: runDirectory,
        modelID: launchModel,
        catalogModelIDs: remoteModels,
        networkAllowed: false,
        sourceEnvironment: sourceEnvironment
      )
      let connected = makeClient(transport: try configuration.transportFactory(launch))
      client = connected
      let initialization = try await connected.initialize()
      try validate(initialization)
      let session = try await connected.newSession(cwd: catalogRoot.path)
      guard
        let modelOption = session.configOptions.first(where: {
          $0.id == "model" || $0.category == "model"
        }), !modelOption.values.isEmpty
      else {
        if remoteModels != nil {
          throw DeepSeekHarnessModelCatalogError.invalidResponse
        }
        await connected.shutdown()
        cleanup(runDirectory: launch.runDirectory, probeRoot: catalogRoot)
        return fallback
      }
      let catalog = Self.modelCatalog(from: modelOption)
      let selected = selectedModelID.flatMap { Self.model(for: $0, in: catalog) }
      let options: [DeepSeekHarnessACPConfigOption]
      let effectiveModelID: String?
      if let selected {
        options = try await connected.setSessionConfigOption(
          sessionID: session.id,
          configID: "model",
          value: selected.wireValue
        )
        effectiveModelID = selected.modelID
      } else {
        options = session.configOptions
        effectiveModelID = Self.currentModelID(in: modelOption, catalog: catalog)
      }
      await connected.shutdown()
      cleanup(runDirectory: launch.runDirectory, probeRoot: catalogRoot)
      return try Self.modelDescriptors(
        from: options,
        selectedModelID: effectiveModelID,
        fallback: fallback
      )
    } catch {
      await client?.shutdown()
      cleanup(runDirectory: runDirectory, probeRoot: catalogRoot)
      throw error
    }
  }

  private struct ModelCatalogEntry: Equatable, Sendable {
    let wireValue: String
    let modelID: String
    let displayName: String
    let modernRoute: Bool
  }

  private static func modelCatalog(
    from option: DeepSeekHarnessACPConfigOption
  ) -> [ModelCatalogEntry] {
    var seenIDs = Set<String>()
    return option.values.compactMap { value in
      let modelID = modelID(from: value.value) ?? value.value
      guard seenIDs.insert(modelID).inserted else { return nil }
      return ModelCatalogEntry(
        wireValue: value.value,
        modelID: modelID,
        displayName: value.name,
        modernRoute: modelID != value.value
      )
    }
  }

  private static func model(
    for selectedModelID: String,
    in catalog: [ModelCatalogEntry]
  ) -> ModelCatalogEntry? {
    catalog.first {
      $0.modelID == selectedModelID || $0.wireValue == selectedModelID
    }
  }

  private static func currentModelID(
    in option: DeepSeekHarnessACPConfigOption,
    catalog: [ModelCatalogEntry]
  ) -> String? {
    guard let currentValue = option.currentValue else { return nil }
    return catalog.first { $0.wireValue == currentValue }?.modelID
      ?? catalog.first { $0.modelID == currentValue }?.modelID
  }

  private static func modelID(from wireValue: String) -> String? {
    guard let data = wireValue.data(using: .utf8),
      let route = try? JSONDecoder().decode([String].self, from: data),
      route.count == 2,
      let provider = route.first,
      let model = route.last,
      !provider.isEmpty,
      !model.isEmpty
    else { return nil }
    return model
  }

  static func modelDescriptors(
    from options: [DeepSeekHarnessACPConfigOption],
    selectedModelID: String?,
    fallback: [AgentModelDescriptor]
  ) throws -> [AgentModelDescriptor] {
    guard
      let modelOption = options.first(where: {
        $0.id == "model" || $0.category == "model"
      }), !modelOption.values.isEmpty
    else {
      return fallback
    }
    let catalog = modelCatalog(from: modelOption)
    let effectiveModelID = selectedModelID ?? currentModelID(in: modelOption, catalog: catalog)
    return try modelDescriptors(
      catalog: catalog,
      options: options,
      selectedModelID: effectiveModelID,
      fallback: fallback
    )
  }

  private static func modelDescriptors(
    catalog: [ModelCatalogEntry],
    options: [DeepSeekHarnessACPConfigOption],
    selectedModelID: String?,
    fallback: [AgentModelDescriptor]
  ) throws -> [AgentModelDescriptor] {
    let modern = catalog.contains(where: \.modernRoute)
    let thoughtLevel = options.first {
      $0.category == "thought_level" || $0.id == "reasoning_effort"
    }
    let dynamicEfforts = thoughtLevel?.values.map(\.value).filter { !$0.isEmpty } ?? []
    let dynamicDefault = thoughtLevel?.currentValue.flatMap { value in
      value.isEmpty ? nil : value
    }
    let fallbackEfforts = fallback.first?.supportedReasoningEfforts ?? []
    let fallbackDefault = fallback.first?.defaultReasoningEffort
    return try catalog.map { entry in
      let useDynamic = modern && entry.modelID == selectedModelID
      return try AgentModelDescriptor(
        id: entry.modelID,
        displayName: entry.displayName,
        supportedReasoningEfforts: useDynamic ? dynamicEfforts : modern ? [] : fallbackEfforts,
        defaultReasoningEffort: useDynamic ? dynamicDefault : modern ? nil : fallbackDefault
      )
    }
  }
}
