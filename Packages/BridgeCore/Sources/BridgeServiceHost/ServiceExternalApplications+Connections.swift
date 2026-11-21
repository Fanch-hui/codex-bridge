import BridgeACP
import BridgeAgentCore
import BridgeDomain
import BridgeSecurity
import BridgeServiceCore
import Foundation

extension ServiceExternalApplications {
  func preview(_ fields: [String: ACPJSONValue]) async throws -> ACPJSONValue {
    let id = try required(fields, "clientID")
    let purpose = try required(fields, "purpose")
    let scope = try required(fields, "scope")
    guard let client = try await readClients().first(where: { $0.id == id && $0.enabled }),
      let agent = ExternalAgentConnectionAgent(rawValue: try required(fields, "agent")),
      client.platform == nil || client.platform == agent.rawValue,
      ["model", "mcp"].contains(purpose), ["global", "project"].contains(scope),
      !(agent == .claudeDesktop && purpose == "model"),
      !(agent == .codexDesktop && purpose == "model" && scope == "project")
    else { throw ServiceStoreError.invalidArgument("external_application.connection") }
    let compatibility = try modelCompatibility(
      fields["compatibility"], agent: agent, purpose: purpose)

    let projectID = scope == "project" ? try required(fields, "projectID") : nil
    let directory = try await configurationDirectory(
      projectID: projectID, client: client, purpose: purpose)
    let path = try configurationURL(agent: agent, purpose: purpose, projectDirectory: directory)
    try await reconcileConnections()
    let matching = try await readConnections().filter {
      $0.clientID == id && $0.agent == agent.rawValue && $0.purpose == purpose
        && $0.scope == scope && $0.projectID == projectID
    }
    guard matching.count <= 1, matching.allSatisfy(\.applied) else {
      throw ExternalAgentConnectionError.configurationChanged
    }
    let previousReceipt = try matching.first.map { try connectionReceipt($0.receiptID) }
    if previewOrder.count >= 16 {
      let oldest = previewOrder.removeFirst()
      previews.removeValue(forKey: oldest)
      await editor.discardPreview(oldest)
    }
    let model: String?
    let gateway: URL?
    let preview: ExternalAgentConnectionPreview
    if purpose == "model" {
      let selectedModel = try required(fields, "model")
      guard client.models.contains(selectedModel) else {
        throw ServiceStoreError.invalidArgument("external_application.model")
      }
      let url = try await endpoint()
      let models: [String]?
      switch agent {
      case .pi, .openCode1, .openCode2:
        models = [selectedModel] + client.models.filter { $0 != selectedModel }
      case .claude where scope == "global":
        models = [selectedModel] + client.models.filter { $0 != selectedModel }
      case .codex, .codexDesktop, .claude, .claudeDesktop:
        models = nil
      }
      preview = try await editor.previewModel(
        agent: agent, configurationURL: path, endpoint: url, model: selectedModel,
        clientToken: token(id), compatibility: compatibility, models: models,
        limits: await modelLimits(), replacing: previousReceipt)
      model = selectedModel
      gateway = url
    } else {
      guard client.mcpEnabled else {
        throw ServiceStoreError.invalidArgument("external_application.mcp_disabled")
      }
      guard appExecutable.isFileURL else {
        throw ServiceStoreError.invalidArgument("external_application.executable")
      }
      preview = try await editor.previewMCP(
        agent: agent, configurationURL: path, command: Self.nativeExecutablePath(appExecutable),
        arguments: ["--mcp-stdio", "--mcp-client", id], replacing: previousReceipt)
      model = nil
      gateway = nil
    }
    let receipt = ExternalAgentConnectionReceipt(previewID: preview.id)
    previews[preview.id] = ServiceExternalConnectionRecord(
      receiptID: receipt.secretReference, clientID: id, agent: agent.rawValue,
      purpose: purpose, scope: scope, projectID: projectID, model: model,
      generation: client.generation, endpoint: gateway?.absoluteString, applied: false,
      replacesReceiptID: matching.first?.receiptID, compatibility: compatibility)
    previewOrder.append(preview.id)
    var warnings: [ACPJSONValue] =
      purpose == "model" && scope == "project"
      ? [.string("项目配置包含 Bridge 访问凭据，请勿提交到版本库。")] : []
    var disabled: [String] = []
    if compatibility["disableWebSearch"] == true { disabled.append("网页搜索") }
    if compatibility["disableMultiAgent"] == true { disabled.append("多 Agent 功能") }
    if compatibility["disableThinking"] == true { disabled.append("扩展思考") }
    if !disabled.isEmpty {
      let selectedScope = scope == "project" ? "所选项目" : "全局"
      let name: String
      switch agent {
      case .codexDesktop: name = "Codex 桌面版"
      case .codex: name = "Codex CLI"
      case .claude, .claudeDesktop: name = "Claude Code"
      case .pi, .openCode1, .openCode2: name = agent.rawValue
      }
      if agent == .codex && compatibility["preserveOfficialLogin"] == true {
        warnings.append(
          .string(
            "codex_bridge 配置组将停用\(disabled.joined(separator: "、"))，仅影响使用 codex -p codex_bridge 启动的会话。"
          ))
      } else {
        warnings.append(
          .string(
            "\(selectedScope)配置将停用\(disabled.joined(separator: "、"))，影响使用该配置的所有 \(name) 会话。"))
      }
    }
    return .object([
      "id": .string(preview.id.uuidString.lowercased()), "agent": .string(agent.rawValue),
      "configurationURL": .string(preview.configurationURL.path),
      "fields": .array(preview.fields.map { .string($0.joined(separator: ".")) }),
      "warnings": .array(warnings),
    ])
  }

  private func modelCompatibility(
    _ value: ACPJSONValue?, agent: ExternalAgentConnectionAgent, purpose: String
  ) throws -> [String: Bool] {
    guard let value else { return [:] }
    guard purpose == "model", let values = value.objectValue else {
      throw ServiceStoreError.invalidArgument("external_application.compatibility")
    }
    let allowed: Set<String>
    switch agent {
    case .codex: allowed = ["disableWebSearch", "disableMultiAgent", "preserveOfficialLogin"]
    case .codexDesktop: allowed = ["disableWebSearch", "disableMultiAgent"]
    case .claude: allowed = ["disableThinking", "preserveOfficialLogin"]
    case .claudeDesktop, .pi, .openCode1, .openCode2: allowed = []
    }
    var result: [String: Bool] = [:]
    for (key, raw) in values {
      guard allowed.contains(key), let selected = raw.boolValue else {
        throw ServiceStoreError.invalidArgument("external_application.compatibility")
      }
      result[key] = selected
    }
    return result
  }

  func apply(_ fields: [String: ACPJSONValue]) async throws -> ACPJSONValue {
    guard let id = UUID(uuidString: try required(fields, "id")), let record = previews[id],
      let client = try await readClients().first(where: { $0.id == record.clientID && $0.enabled }),
      client.generation == record.generation
    else { throw ServiceStoreError.invalidArgument("external_application.preview_expired") }
    if let model = record.model {
      guard client.models.contains(model),
        try await endpoint().absoluteString == record.endpoint
      else { throw ServiceStoreError.invalidArgument("external_application.preview_expired") }
    } else {
      guard client.mcpEnabled else {
        throw ServiceStoreError.invalidArgument("external_application.preview_expired")
      }
    }
    _ = try await configurationDirectory(
      projectID: record.projectID, client: client, purpose: record.purpose)
    var records = try await readConnections()
    guard !records.contains(where: { $0.receiptID == record.receiptID }) else {
      throw ServiceStoreError.invalidArgument("external_application.receipt")
    }
    if let previousID = record.replacesReceiptID {
      guard records.contains(where: { $0.receiptID == previousID && $0.applied }) else {
        throw ExternalAgentConnectionError.configurationChanged
      }
    }
    records.append(record)
    try await writeConnections(records)
    do {
      let receipt = try await editor.apply(id)
      guard receipt.secretReference == record.receiptID else {
        throw ServiceStoreError.invalidArgument("external_application.receipt")
      }
    } catch let operationError {
      do {
        _ = try secrets.load(SecretReference(validating: record.receiptID))
      } catch SecretStoreError.notFound {
        records.removeAll { $0.receiptID == record.receiptID }
        try await writeConnections(records)
      } catch let cleanupError {
        throw ServiceExternalApplicationsCleanupFailure(
          operationError: operationError, cleanupError: cleanupError)
      }
      throw operationError
    }
    records[records.count - 1].applied = true
    try await writeConnections(records)
    if let previousID = record.replacesReceiptID {
      try secrets.remove(SecretReference(validating: previousID))
      records.removeAll { $0.receiptID == previousID }
      try await writeConnections(records)
    }
    previews.removeValue(forKey: id)
    previewOrder.removeAll { $0 == id }
    return .object(["receiptID": .string(record.receiptID)])
  }

  func revert(_ fields: [String: ACPJSONValue]) async throws -> ACPJSONValue {
    let receiptID = try required(fields, "receiptID")
    let receipt = try connectionReceipt(receiptID)
    var records = try await readConnections()
    guard records.contains(where: { $0.receiptID == receiptID }) else {
      throw ServiceStoreError.invalidArgument("external_application.receipt")
    }
    try await editor.revert(receipt)
    records.removeAll { $0.receiptID == receiptID }
    try await writeConnections(records)
    return .object([:])
  }

  func reconcileConnections() async throws {
    let records = try await readConnections()
    var existing: [ServiceExternalConnectionRecord] = []
    for var record in records {
      do {
        _ = try secrets.load(SecretReference(validating: record.receiptID))
      } catch SecretStoreError.notFound {
        // A crash before journal creation or after a completed revert leaves only this record.
        continue
      }
      if !record.applied, record.replacesReceiptID == nil {
        let receipt = try connectionReceipt(record.receiptID)
        switch try await editor.initialPublication(receipt) {
        case .applied: record.applied = true
        case .notApplied:
          try secrets.remove(SecretReference(validating: record.receiptID))
          continue
        case .uncertain: break
        }
      }
      existing.append(record)
    }
    for record in existing {
      guard let previousID = record.replacesReceiptID else { continue }
      let replacementApplied: Bool
      if record.applied {
        replacementApplied = true
      } else {
        replacementApplied = try await editor.isApplied(connectionReceipt(record.receiptID))
      }
      if replacementApplied {
        if existing.contains(where: { $0.receiptID == previousID }) {
          try secrets.remove(SecretReference(validating: previousID))
          existing.removeAll { $0.receiptID == previousID }
        }
        if let index = existing.firstIndex(where: { $0.receiptID == record.receiptID }) {
          existing[index].applied = true
        }
      } else if existing.contains(where: { $0.receiptID == previousID }),
        try await editor.isApplied(connectionReceipt(previousID))
      {
        try secrets.remove(SecretReference(validating: record.receiptID))
        existing.removeAll { $0.receiptID == record.receiptID }
      }
    }
    for index in existing.indices where existing[index].compatibility == nil {
      let receipt = try connectionReceipt(existing[index].receiptID)
      let compatibility = try await editor.compatibility(receipt)
      existing[index].compatibility = compatibility
    }
    if existing != records { try await writeConnections(existing) }
  }

  private func connectionReceipt(_ reference: String) throws -> ExternalAgentConnectionReceipt {
    let prefix = "agent-connection."
    guard reference.hasPrefix(prefix),
      let id = UUID(uuidString: String(reference.dropFirst(prefix.count)))
    else { throw ServiceStoreError.invalidArgument("external_application.receipt") }
    let receipt = ExternalAgentConnectionReceipt(previewID: id)
    guard receipt.secretReference == reference else {
      throw ServiceStoreError.invalidArgument("external_application.receipt")
    }
    return receipt
  }

  private func configurationDirectory(
    projectID: String?, client: ServiceExternalApplication, purpose: String
  ) async throws -> URL? {
    guard let projectID else { return nil }
    if purpose == "mcp", !client.projectIDs.contains(projectID) {
      throw ServiceStoreError.invalidArgument("external_application.projectIDs")
    }
    guard let project = try await projects.project(id: ProjectID(rawValue: projectID)) else {
      throw ServiceStoreError.invalidArgument("external_application.projectIDs")
    }
    try project.root.validateCurrentIdentity()
    return URL(fileURLWithPath: project.root.canonicalPath, isDirectory: true)
  }

  static func nativeExecutablePath(_ url: URL) -> String {
    #if os(Windows)
      url.withUnsafeFileSystemRepresentation { pointer in
        guard let pointer else { return url.path }
        return String(cString: pointer)
      }
    #else
      url.path
    #endif
  }

  private static func environmentValue(_ key: String, from env: [String: String]) -> String? {
    #if os(Windows)
      AgentProviderEnvironment.environmentValue(key, source: env)
    #else
      env[key]
    #endif
  }

  private func configurationURL(
    agent: ExternalAgentConnectionAgent, purpose: String, projectDirectory: URL?
  ) throws -> URL {
    let env = ProcessInfo.processInfo.environment
    switch agent {
    case .pi:
      guard projectDirectory == nil else {
        throw ServiceStoreError.invalidArgument("external_application.connection")
      }
      return configuredDirectory(
        Self.environmentValue("PI_CODING_AGENT_DIR", from: env),
        fallback: homeDirectory.appendingPathComponent(".pi/agent")
      ).appendingPathComponent(purpose == "model" ? "models.json" : "mcp.json")
    case .codex:
      let root =
        projectDirectory?.appendingPathComponent(".codex", isDirectory: true)
        ?? configuredDirectory(
          Self.environmentValue("CODEX_HOME", from: env),
          fallback: homeDirectory.appendingPathComponent(".codex"))
      return root.appendingPathComponent("config.toml")
    case .codexDesktop:
      guard projectDirectory == nil else {
        throw ServiceStoreError.invalidArgument("external_application.connection")
      }
      return configuredDirectory(
        Self.environmentValue("CODEX_HOME", from: env),
        fallback: homeDirectory.appendingPathComponent(".codex")
      ).appendingPathComponent("config.toml")
    case .claude:
      if let projectDirectory {
        return projectDirectory.appendingPathComponent(
          purpose == "mcp" ? ".mcp.json" : ".claude/settings.local.json")
      }
      let claudeConfigDir = Self.environmentValue("CLAUDE_CONFIG_DIR", from: env)
      let custom = configuredDirectory(
        claudeConfigDir, fallback: homeDirectory.appendingPathComponent(".claude"))
      if purpose == "model" { return custom.appendingPathComponent("settings.json") }
      return claudeConfigDir == nil
        ? homeDirectory.appendingPathComponent(".claude.json")
        : custom.appendingPathComponent(".claude.json")
    case .claudeDesktop:
      guard projectDirectory == nil, purpose == "mcp" else {
        throw ServiceStoreError.invalidArgument("external_application.connection")
      }
      #if os(macOS)
        return homeDirectory.appendingPathComponent(
          "Library/Application Support/Claude/claude_desktop_config.json")
      #elseif os(Windows)
        return configuredDirectory(
          Self.environmentValue("APPDATA", from: env),
          fallback: homeDirectory.appendingPathComponent("AppData/Roaming")
        ).appendingPathComponent("Claude/claude_desktop_config.json")
      #else
        return configuredDirectory(
          Self.environmentValue("XDG_CONFIG_HOME", from: env),
          fallback: homeDirectory.appendingPathComponent(".config")
        ).appendingPathComponent("Claude/claude_desktop_config.json")
      #endif
    case .openCode1, .openCode2:
      let global = configuredDirectory(
        Self.environmentValue("XDG_CONFIG_HOME", from: env),
        fallback: homeDirectory.appendingPathComponent(".config")
      )
      .appendingPathComponent("opencode", isDirectory: true)
      let root = projectDirectory ?? global
      let nested = root.appendingPathComponent(".opencode", isDirectory: true)
      if projectDirectory != nil, Self.hasOpenCodeConfiguration(nested) {
        return try Self.openCodeConfiguration(nested)
      }
      return try Self.openCodeConfiguration(root)
    }
  }

  private func configuredDirectory(_ path: String?, fallback: URL) -> URL {
    guard let path, !path.isEmpty else { return fallback }
    return URL(fileURLWithPath: path, isDirectory: true)
  }

  private static func hasOpenCodeConfiguration(_ root: URL) -> Bool {
    ["opencode.json", "opencode.jsonc"].contains {
      FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path)
    }
  }

  private static func openCodeConfiguration(_ root: URL) throws -> URL {
    let json = root.appendingPathComponent("opencode.json")
    let jsonc = root.appendingPathComponent("opencode.jsonc")
    let manager = FileManager.default
    guard !manager.fileExists(atPath: json.path) || !manager.fileExists(atPath: jsonc.path) else {
      throw ServiceStoreError.invalidArgument("external_application.multiple_opencode_configs")
    }
    return manager.fileExists(atPath: jsonc.path) ? jsonc : json
  }
}
