import BridgeACP
import BridgeSecurity
import Foundation

public actor ExternalAgentConnection {
  public typealias Editor = @Sendable (Data) async throws -> Data

  private struct Pending: Sendable {
    let agent: ExternalAgentConnectionAgent
    let url: URL
    let previous: Data?
    let next: Data
    let changes: [ACPJSONValue]
  }

  private struct Journal: Codable, Sendable {
    let agent: ExternalAgentConnectionAgent
    let configurationURL: URL
    let changes: [ACPJSONValue]
    let previousSHA256: String?
    let nextSHA256: String?
  }

  private let editor: Editor
  private let secrets: any SecretStore
  private var previews: [UUID: Pending] = [:]

  public init(secrets: any SecretStore, editor: @escaping Editor) {
    self.secrets = secrets
    self.editor = editor
  }

  public func previewModel(
    agent: ExternalAgentConnectionAgent, configurationURL: URL, endpoint: URL, model: String,
    clientToken: String, compatibility: [String: Bool] = [:], models: [String]? = nil,
    replacing receipt: ExternalAgentConnectionReceipt? = nil
  ) async throws -> ExternalAgentConnectionPreview {
    var options: [String: ACPJSONValue] = [
      "endpoint": .string(endpoint.absoluteString), "model": .string(model),
      "token": .string(clientToken),
      "compatibility": .object(compatibility.mapValues { .bool($0) }),
    ]
    if let models { options["models"] = .array(models.map(ACPJSONValue.string)) }
    return try await prepare(
      agent: agent, configurationURL: configurationURL, purpose: "model",
      options: .object(options), replacing: receipt)
  }

  public func previewMCP(
    agent: ExternalAgentConnectionAgent, configurationURL: URL, command: String,
    arguments: [String], replacing receipt: ExternalAgentConnectionReceipt? = nil
  ) async throws -> ExternalAgentConnectionPreview {
    try await prepare(
      agent: agent, configurationURL: configurationURL, purpose: "mcp",
      options: .object([
        "command": .string(command), "args": .array(arguments.map(ACPJSONValue.string)),
      ]), replacing: receipt)
  }

  public func discardPreview(_ id: UUID) {
    previews.removeValue(forKey: id)
  }

  public func apply(_ id: UUID) throws -> ExternalAgentConnectionReceipt {
    guard let pending = previews[id] else { throw ExternalAgentConnectionError.invalidPreview }
    guard try read(pending.url) == pending.previous else {
      throw ExternalAgentConnectionError.configurationChanged
    }
    let receipt = ExternalAgentConnectionReceipt(previewID: id)
    let reference = try SecretReference(validating: receipt.secretReference)
    let journal = Journal(
      agent: pending.agent, configurationURL: pending.url, changes: pending.changes,
      previousSHA256: pending.previous.map { SecureFileRevision.digest(of: $0).sha256 },
      nextSHA256: SecureFileRevision.digest(of: pending.next).sha256)
    try secrets.store(JSONEncoder().encode(journal), for: reference)
    do {
      try publish(pending.next, at: pending.url)
    } catch let operationError {
      do { try secrets.remove(reference) } catch let cleanupError {
        throw ExternalAgentConnectionCleanupFailure(
          operation: .apply, operationError: operationError, cleanupError: cleanupError)
      }
      throw operationError
    }
    previews.removeValue(forKey: id)
    return receipt
  }

  public func revert(_ receipt: ExternalAgentConnectionReceipt) async throws {
    let journal = try loadJournal(receipt)
    guard let original = try read(journal.configurationURL),
      let source = String(data: original, encoding: .utf8)
    else { throw ExternalAgentConnectionError.configurationChanged }
    let result = try await invoke(
      .object([
        "operation": .string("revert"), "agent": .string(journal.agent.rawValue),
        "content": .string(source), "changes": .array(journal.changes),
      ]))
    if let conflicts = result["conflicts"]?.arrayValue {
      let paths = try conflicts.map(Self.path)
      throw ExternalAgentConnectionError.conflictingFields(paths)
    }
    guard let content = result["content"]?.stringValue else {
      throw ExternalAgentConnectionError.invalidConfiguration
    }
    guard try read(journal.configurationURL) == original else {
      throw ExternalAgentConnectionError.configurationChanged
    }
    try publish(Data(content.utf8), at: journal.configurationURL)
    do { try secrets.remove(SecretReference(validating: receipt.secretReference)) } catch {
      throw ExternalAgentConnectionCleanupFailure(
        operation: .revert, operationError: nil, cleanupError: error)
    }
  }

  enum InitialPublication {
    case applied, notApplied, uncertain
  }

  func initialPublication(_ receipt: ExternalAgentConnectionReceipt) async throws
    -> InitialPublication
  {
    let journal = try loadJournal(receipt)
    if let expected = journal.nextSHA256 {
      let current = try read(journal.configurationURL).map {
        SecureFileRevision.digest(of: $0).sha256
      }
      if current == expected { return .applied }
      if current == journal.previousSHA256 { return .notApplied }
      return .uncertain
    }
    // Older journals only describe the managed fields, not the original file revision.
    return try await isApplied(journal) ? .applied : .uncertain
  }

  func isApplied(_ receipt: ExternalAgentConnectionReceipt) async throws -> Bool {
    try await isApplied(loadJournal(receipt))
  }

  private func isApplied(_ journal: Journal) async throws -> Bool {
    guard let original = try read(journal.configurationURL),
      let source = String(data: original, encoding: .utf8)
    else { return false }
    let result = try await invoke(
      .object([
        "operation": .string("revert"), "agent": .string(journal.agent.rawValue),
        "content": .string(source), "changes": .array(journal.changes),
      ]))
    guard try read(journal.configurationURL) == original else {
      throw ExternalAgentConnectionError.configurationChanged
    }
    if result["conflicts"]?.arrayValue != nil { return false }
    guard result["content"]?.stringValue != nil else {
      throw ExternalAgentConnectionError.invalidConfiguration
    }
    return true
  }

  func compatibility(_ receipt: ExternalAgentConnectionReceipt) throws -> [String: Bool] {
    let journal = try loadJournal(receipt)
    var options: [String: Bool] = [:]
    for change in journal.changes {
      let path = try Self.path(change["path"] ?? .null)
      let after = change["after"]
      guard after?["exists"]?.boolValue == true else { continue }
      if journal.agent == .codex || journal.agent == .codexDesktop {
        if path == ["web_search"], after?["value"]?.stringValue == "disabled" {
          options["disableWebSearch"] = true
        }
        if path == ["features", "multi_agent"], after?["value"]?.boolValue == false {
          options["disableMultiAgent"] = true
        }
        if journal.agent == .codex, path == ["profiles", "codex_bridge"],
          let profile = after?["value"]?.objectValue
        {
          options["preserveOfficialLogin"] = true
          if profile["web_search"]?.stringValue == "disabled" {
            options["disableWebSearch"] = true
          }
          if profile["features"]?["multi_agent"]?.boolValue == false {
            options["disableMultiAgent"] = true
          }
        }
      } else if journal.agent == .claude {
        if path == ["env", "CLAUDE_CODE_DISABLE_THINKING"], after?["value"]?.stringValue == "1" {
          options["disableThinking"] = true
        }
        if path == ["env", "ANTHROPIC_CUSTOM_HEADERS"] {
          options["preserveOfficialLogin"] = true
        }
      }
    }
    return options
  }

  private func prepare(
    agent: ExternalAgentConnectionAgent, configurationURL: URL, purpose: String,
    options: ACPJSONValue, replacing receipt: ExternalAgentConnectionReceipt?
  ) async throws -> ExternalAgentConnectionPreview {
    guard configurationURL.isFileURL, previews.count < 16 else {
      throw ExternalAgentConnectionError.invalidConfiguration
    }
    let previous = try read(configurationURL)
    let source: ACPJSONValue
    if let previous {
      guard previous.count <= 2 * 1_024 * 1_024,
        let content = String(data: previous, encoding: .utf8)
      else { throw ExternalAgentConnectionError.invalidConfiguration }
      source = .string(content)
    } else {
      source = .null
    }
    var request: [String: ACPJSONValue] = [
      "operation": .string("prepare"), "agent": .string(agent.rawValue),
      "purpose": .string(purpose), "content": source, purpose: options,
    ]
    if let receipt {
      let journal = try loadJournal(receipt)
      guard journal.agent == agent,
        journal.configurationURL.standardizedFileURL == configurationURL.standardizedFileURL
      else { throw ExternalAgentConnectionError.invalidConfiguration }
      request["previousChanges"] = .array(journal.changes)
    }
    let result = try await invoke(.object(request))
    if let conflicts = result["conflicts"]?.arrayValue {
      throw ExternalAgentConnectionError.conflictingFields(try conflicts.map(Self.path))
    }
    guard let next = result["content"]?.stringValue,
      let changes = result["changes"]?.arrayValue
    else { throw ExternalAgentConnectionError.invalidConfiguration }
    let fields: [[String]]
    if let paths = result["fields"]?.arrayValue {
      fields = try paths.map(Self.path)
    } else {
      fields = try changes.map { change in try Self.path(change["path"] ?? .null) }
    }
    let id = UUID()
    previews[id] = Pending(
      agent: agent, url: configurationURL, previous: previous, next: Data(next.utf8),
      changes: changes)
    return ExternalAgentConnectionPreview(
      id: id, agent: agent, configurationURL: configurationURL, fields: fields)
  }

  private func loadJournal(_ receipt: ExternalAgentConnectionReceipt) throws -> Journal {
    let prefix = "agent-connection."
    guard receipt.secretReference.hasPrefix(prefix),
      let id = UUID(uuidString: String(receipt.secretReference.dropFirst(prefix.count))),
      ExternalAgentConnectionReceipt(previewID: id) == receipt
    else { throw ExternalAgentConnectionError.invalidConfiguration }
    let reference = try SecretReference(validating: receipt.secretReference)
    return try JSONDecoder().decode(Journal.self, from: secrets.load(reference))
  }

  private func invoke(_ request: ACPJSONValue) async throws -> ACPJSONValue {
    let data = try await editor(request.encodedData())
    let response = try JSONDecoder().decode(ACPJSONValue.self, from: data)
    if let error = response["error"]?.stringValue {
      throw ExternalAgentConnectionError.editorFailed(error)
    }
    guard let result = response["result"] else {
      throw ExternalAgentConnectionError.invalidConfiguration
    }
    return result
  }

  private static func path(_ value: ACPJSONValue) throws -> [String] {
    guard let array = value.arrayValue else {
      throw ExternalAgentConnectionError.invalidConfiguration
    }
    return try array.map {
      guard let value = $0.stringValue else {
        throw ExternalAgentConnectionError.invalidConfiguration
      }
      return value
    }
  }

  private func read(_ url: URL) throws -> Data? {
    do {
      return try Data(contentsOf: url)
    } catch CocoaError.fileReadNoSuchFile {
      return nil
    }
  }

  private func publish(_ data: Data, at url: URL) throws {
    let manager = FileManager.default
    let parent = url.deletingLastPathComponent()
    try manager.createDirectory(
      at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let staged = parent.appendingPathComponent(".codex-bridge-\(UUID().uuidString).tmp")
    guard
      manager.createFile(
        atPath: staged.path, contents: data, attributes: [.posixPermissions: 0o600])
    else { throw CocoaError(.fileWriteUnknown) }
    do {
      try FileReplacement.publish(staged, at: url)
    } catch let operationError {
      do { try manager.removeItem(at: staged) } catch let cleanupError {
        throw ExternalAgentConnectionCleanupFailure(
          operation: .publish, operationError: operationError, cleanupError: cleanupError)
      }
      throw operationError
    }
  }
}
