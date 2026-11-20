import BridgeACP
import BridgeMCP
import BridgeSecurity
import BridgeServiceCore
import Foundation

extension ServiceExternalApplications {
  func create(_ fields: [String: ACPJSONValue]) async throws -> ACPJSONValue {
    let input = try await parseClient(fields, id: "", generation: 1)
    let registered = try await mcpClients.registerExternal(displayName: input.name)
    var client = input
    client.id = registered.id
    let reference = try tokenReference(client.id)
    do {
      let token = try ServiceMCPSecretProvider.secureRandomBytes(count: 32).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
      try secrets.store(Data(token.utf8), for: reference)
      let clients = try await readClients() + [client]
      try await writeClients(clients)
      try await mcpClients.updateExternal(mcpRecord(client))
      try publish(clients)
      return client.presentation
    } catch let operationError {
      do {
        var disabled = mcpRecord(client)
        disabled.enabled = false
        try await mcpClients.updateExternal(disabled)
        let current = try await readClients()
        try await writeClients(current.filter { $0.id != client.id })
        try await mcpClients.removeExternal(id: client.id)
        do { try secrets.remove(reference) } catch SecretStoreError.notFound {}
        try publish(current.filter { $0.id != client.id })
      } catch let cleanupError {
        throw ServiceExternalApplicationsCleanupFailure(
          operationError: operationError, cleanupError: cleanupError)
      }
      throw operationError
    }
  }

  func update(_ fields: [String: ACPJSONValue]) async throws -> ACPJSONValue {
    let id = try required(fields, "id")
    let previous = try await readClients()
    guard let index = previous.firstIndex(where: { $0.id == id }),
      previous[index].generation < UInt64.max
    else { throw ServiceStoreError.invalidArgument("external_application.id") }
    let client = try await parseClient(
      fields, id: id, generation: previous[index].generation + 1,
      previousPlatform: previous[index].platform)
    var disabled = mcpRecord(previous[index])
    disabled.enabled = false
    do {
      try await mcpClients.updateExternal(disabled)
      try publish(previous, excluding: id)
      var clients = previous
      clients[index] = client
      try await writeClients(clients)
      try await mcpClients.updateExternal(mcpRecord(client))
      try publish(clients)
      return client.presentation
    } catch let operationError {
      do {
        try await mcpClients.updateExternal(disabled)
        try await writeClients(previous)
        try await mcpClients.updateExternal(mcpRecord(previous[index]))
        try publish(previous)
      } catch let cleanupError {
        throw ServiceExternalApplicationsCleanupFailure(
          operationError: operationError, cleanupError: cleanupError)
      }
      throw operationError
    }
  }

  func revoke(_ fields: [String: ACPJSONValue]) async throws -> ACPJSONValue {
    let id = try required(fields, "id")
    let previous = try await readClients()
    guard let index = previous.firstIndex(where: { $0.id == id }) else {
      throw ServiceStoreError.invalidArgument("external_application.id")
    }
    var disabled = mcpRecord(previous[index])
    disabled.enabled = false
    do {
      try await mcpClients.updateExternal(disabled)
      try publish(previous, excluding: id)
      try await writeClients(previous.filter { $0.id != id })
    } catch let operationError {
      do {
        try await writeClients(previous)
        try await mcpClients.updateExternal(mcpRecord(previous[index]))
        try publish(previous)
      } catch let cleanupError {
        throw ServiceExternalApplicationsCleanupFailure(
          operationError: operationError, cleanupError: cleanupError)
      }
      throw operationError
    }
    try await mcpClients.removeExternal(id: id)
    try secrets.remove(tokenReference(id))
    return .object([:])
  }

  func configuration(_ fields: [String: ACPJSONValue]) async throws -> ACPJSONValue {
    let id = try required(fields, "id")
    guard let client = try await readClients().first(where: { $0.id == id && $0.enabled }) else {
      throw ServiceStoreError.invalidArgument("external_application.id")
    }
    if client.platform == "claude_desktop", !client.models.isEmpty {
      let url = try await endpoint()
      let configuration = try await claudeDesktopGatewayConfiguration(
        client: client, endpointURL: url)
      return .object(["configuration": .string(configuration)])
    }
    var sections: [String] = []
    if !client.models.isEmpty {
      let url = try await endpoint()
      sections.append(
        """
        OpenAI 兼容接口：\(url.absoluteString)
        Anthropic 接口：\(url.deletingLastPathComponent().absoluteString)
        访问凭据：\(try token(id))
        允许使用的模型：\(client.models.joined(separator: ", "))
        """)
    }
    if client.mcpEnabled {
      let server: ACPJSONValue = .object([
        "command": .string(Self.nativeExecutablePath(appExecutable)),
        "args": .array(["--mcp-stdio", "--mcp-client", id].map(ACPJSONValue.string)),
      ])
      let json = String(decoding: try server.encodedData(), as: UTF8.self)
      sections.append("本地 stdio MCP 配置：\n\(json)")
    }
    guard !sections.isEmpty else {
      throw ServiceStoreError.invalidArgument("external_application.no_access")
    }
    return .object(["configuration": .string(sections.joined(separator: "\n\n"))])
  }

  private func claudeDesktopGatewayConfiguration(
    client: ServiceExternalApplication, endpointURL: URL
  ) async throws -> String {
    var baseURL = endpointURL.deletingLastPathComponent().absoluteString
    while baseURL.hasSuffix("/") { baseURL.removeLast() }
    let displayNames = await modelNames()
    let inferenceModels: [[String: String]] = client.models.map { modelID in
      let label = displayNames[modelID]?.trimmingCharacters(in: .whitespacesAndNewlines)
      return [
        "name": modelID,
        "labelOverride": (label?.isEmpty == false ? label! : modelID),
      ]
    }
    let payload: [String: Any] = [
      "inferenceProvider": "gateway",
      "inferenceGatewayBaseUrl": baseURL,
      "inferenceGatewayApiKey": try token(client.id),
      "inferenceCredentialKind": "static",
      "inferenceGatewayAuthScheme": "bearer",
      "inferenceModels": inferenceModels,
    ]
    let data = try JSONSerialization.data(
      withJSONObject: payload, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    return String(decoding: data, as: UTF8.self)
  }

  func mcpRecord(_ application: ServiceExternalApplication) -> ServiceExternalMCPClient {
    var tools: [MCPServiceToolName] = [.bridgeStatus, .listProjects]
    if !application.projectIDs.isEmpty {
      tools += [
        .getProject, .searchProjectFiles, .listProjectDirectory, .batchReadProjectFiles,
        .readProjectFile, .getProjectChanges, .directWriteProjectFile, .directEditProjectFile,
        .directApplyProjectPatch, .directManageProjectPath,
      ]
      if application.allowCommands {
        tools += [
          .directExecCommand, .listDirectCommands, .directReadCommand, .directWriteStdin,
          .directInterruptCommand, .directGitCommit,
        ]
      }
    }
    return ServiceExternalMCPClient(
      id: application.id, displayName: application.name,
      enabled: application.enabled && application.mcpEnabled,
      allowedProjectIDs: application.projectIDs, allowedToolNames: tools.map(\.rawValue))
  }

  private func parseClient(
    _ fields: [String: ACPJSONValue], id: String, generation: UInt64,
    previousPlatform: String? = nil
  ) async throws -> ServiceExternalApplication {
    let name = try required(fields, "name").trimmingCharacters(in: .whitespacesAndNewlines)
    let models = try stringArray(fields["models"], name: "models")
    let projectIDs = try stringArray(fields["projectIDs"], name: "projectIDs")
    guard !name.isEmpty, name.utf8.count <= 128,
      let mcpEnabled = fields["mcpEnabled"]?.boolValue,
      let allowCommands = fields["allowCommands"]?.boolValue,
      id.isEmpty || fields["enabled"]?.boolValue != nil
    else { throw ServiceStoreError.invalidArgument("external_application.configuration") }
    var platform = previousPlatform
    if let value = fields["platform"] {
      guard let selected = value.stringValue,
        selected == "other" || ExternalAgentConnectionAgent(rawValue: selected) != nil
      else { throw ServiceStoreError.invalidArgument("external_application.platform") }
      platform = selected
    }
    let preserveOfficialLogin: Bool
    if let rawPreserve = fields["preserveOfficialLogin"] {
      guard let selected = rawPreserve.boolValue else {
        throw ServiceStoreError.invalidArgument("external_application.configuration")
      }
      preserveOfficialLogin = selected
    } else {
      preserveOfficialLogin = false
    }
    if preserveOfficialLogin {
      guard platform == "codex" || platform == "claude" else {
        throw ServiceStoreError.invalidArgument("external_application.configuration")
      }
    }
    let registered = Set(try await projects.projects().map { $0.id.rawValue })
    guard Set(projectIDs).isSubset(of: registered) else {
      throw ServiceStoreError.invalidArgument("external_application.projectIDs")
    }
    return ServiceExternalApplication(
      id: id, name: name, platform: platform,
      enabled: id.isEmpty ? true : fields["enabled"]!.boolValue!,
      models: models, mcpEnabled: mcpEnabled, projectIDs: projectIDs,
      allowCommands: allowCommands, preserveOfficialLogin: preserveOfficialLogin,
      generation: generation)
  }

  private func stringArray(_ value: ACPJSONValue?, name: String) throws -> [String] {
    guard let array = value?.arrayValue, array.count <= 128 else {
      throw ServiceStoreError.invalidArgument("external_application.\(name)")
    }
    let values = try array.map { item -> String in
      guard let string = item.stringValue, !string.isEmpty, string.utf8.count <= 512 else {
        throw ServiceStoreError.invalidArgument("external_application.\(name)")
      }
      return string
    }
    guard Set(values).count == values.count else {
      throw ServiceStoreError.invalidArgument("external_application.\(name)")
    }
    return values
  }
}
