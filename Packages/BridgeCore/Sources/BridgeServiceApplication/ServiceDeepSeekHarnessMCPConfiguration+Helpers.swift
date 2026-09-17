import BridgeAgentCore
import BridgeSecurity
import BridgeServiceCore
import Crypto
import Foundation

extension ServiceDeepSeekHarnessMCPConfiguration {
  func makeRecord(
    _ input: ServiceDeepSeekHarnessMCPServerInput,
    existingRecords: [ServiceDeepSeekHarnessMCPServerRecord]
  ) throws -> ServiceDeepSeekHarnessMCPServerRecord {
    guard input.environment.count <= 128, input.headers.count <= 128 else {
      throw ServiceStoreError.invalidArgument("dsh.mcp.secrets")
    }
    try validateSecretInputs(input.environment, field: "dsh.mcp.environment")
    try validateSecretInputs(input.headers, field: "dsh.mcp.headers")
    if input.transport == .stdio, !input.headers.isEmpty {
      throw ServiceStoreError.invalidArgument("dsh.mcp.headers")
    }
    if input.transport == .http, !input.environment.isEmpty {
      throw ServiceStoreError.invalidArgument("dsh.mcp.environment")
    }
    let normalizedName = input.name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedName.isEmpty else {
      throw ServiceStoreError.invalidArgument("dsh.mcp.name")
    }
    if input.transport == .stdio {
      guard let command = input.command, AgentPathSemantics.isAbsolute(command) else {
        throw ServiceStoreError.invalidArgument("dsh.mcp.command")
      }
    }
    let otherRecords = existingRecords.filter { $0.id != input.id }
    guard otherRecords.allSatisfy({ $0.name != normalizedName }) else {
      throw ServiceStoreError.invalidArgument("dsh.mcp.name")
    }
    try validateHTTPURL(input.url, transport: input.transport)
    return try ServiceDeepSeekHarnessMCPServerRecord(
      id: input.id,
      name: normalizedName,
      enabled: input.enabled,
      transport: input.transport,
      command: input.command,
      args: input.args,
      url: input.url,
      environmentNames: input.environment.map(\.name),
      headerNames: input.headers.map(\.name)
    )
  }

  func validateSecretInputs(
    _ inputs: [ServiceDeepSeekHarnessMCPSecretInput],
    field: String
  ) throws {
    var names = Set<String>()
    for input in inputs {
      guard !input.name.isEmpty,
        input.name == input.name.trimmingCharacters(in: .whitespacesAndNewlines),
        input.name.utf8.count <= 256,
        !input.name.contains("\0"),
        input.name.rangeOfCharacter(from: .controlCharacters) == nil
      else {
        throw ServiceStoreError.invalidArgument(field)
      }
      var nameKey = input.name
      if field.hasSuffix("headers") { nameKey = nameKey.lowercased() }
      #if os(Windows)
        nameKey = nameKey.lowercased()
      #endif
      guard names.insert(nameKey).inserted else {
        throw ServiceStoreError.invalidArgument(field)
      }
      if field.hasSuffix("headers") {
        guard input.name.unicodeScalars.allSatisfy(Self.isHTTPHeaderName) else {
          throw ServiceStoreError.invalidArgument(field)
        }
      } else {
        guard !input.name.contains("=") else {
          throw ServiceStoreError.invalidArgument(field)
        }
      }
      if let value = input.value {
        guard value.utf8.count <= 16 * 1_024,
          !value.contains("\0"),
          !value.unicodeScalars.contains(where: Self.isUnsafeTextScalar),
          !field.hasSuffix("headers") || (!value.contains("\r") && !value.contains("\n"))
        else {
          throw ServiceStoreError.invalidArgument("\(field).value")
        }
      }
    }
  }

  func validateHTTPURL(
    _ value: String?,
    transport: ServiceDeepSeekHarnessMCPTransport
  ) throws {
    if transport == .stdio {
      guard value == nil else { throw ServiceStoreError.invalidArgument("dsh.mcp.url") }
      return
    }
    guard let value, let url = URL(string: value),
      let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
      url.host != nil, url.user == nil, url.password == nil,
      url.fragment == nil,
      value.utf8.count <= 4 * 1_024
    else {
      throw ServiceStoreError.invalidArgument("dsh.mcp.url")
    }
  }

  func storeProvidedSecrets(_ input: ServiceDeepSeekHarnessMCPServerInput) throws {
    for field in input.environment {
      try store(field, kind: "env", serverID: input.id)
    }
    for field in input.headers {
      try store(field, kind: "header", serverID: input.id)
    }
  }

  func store(
    _ field: ServiceDeepSeekHarnessMCPSecretInput,
    kind: String,
    serverID: String
  ) throws {
    guard let value = field.value, !value.isEmpty else { return }
    let reference = try secretReference(serverID: serverID, kind: kind, name: field.name)
    do {
      try secretStore.store(Data(value.utf8), for: reference)
    } catch {
      throw ServiceDeepSeekHarnessMCPError.secretStoreUnavailable
    }
  }

  func summary(
    for record: ServiceDeepSeekHarnessMCPServerRecord
  ) throws -> ServiceDeepSeekHarnessMCPServerSummary {
    ServiceDeepSeekHarnessMCPServerSummary(
      id: record.id,
      name: record.name,
      enabled: record.enabled,
      transport: record.transport,
      command: record.command,
      args: record.args,
      url: record.url,
      environment: try secretSummaries(for: record, kind: "env", names: record.environmentNames),
      headers: try secretSummaries(for: record, kind: "header", names: record.headerNames)
    )
  }

  func secretSummaries(
    for record: ServiceDeepSeekHarnessMCPServerRecord,
    kind: String,
    names: [String]
  ) throws -> [ServiceDeepSeekHarnessMCPSecretSummary] {
    try names.map { name in
      ServiceDeepSeekHarnessMCPSecretSummary(
        name: name,
        hasValue: try hasSecret(serverID: record.id, kind: kind, name: name)
      )
    }
  }

  func hasSecret(serverID: String, kind: String, name: String) throws -> Bool {
    let reference = try secretReference(serverID: serverID, kind: kind, name: name)
    do {
      _ = try secretStore.load(reference)
      return true
    } catch SecretStoreError.notFound {
      return false
    } catch {
      throw ServiceDeepSeekHarnessMCPError.secretStoreUnavailable
    }
  }

  func loadSecrets(
    for record: ServiceDeepSeekHarnessMCPServerRecord,
    kind: String,
    names: [String]
  ) throws -> [String: String] {
    Dictionary(
      uniqueKeysWithValues: try names.map { name in
        (name, try loadSecret(serverID: record.id, kind: kind, name: name))
      })
  }

  func loadSecret(serverID: String, kind: String, name: String) throws -> String {
    let reference = try secretReference(serverID: serverID, kind: kind, name: name)
    do {
      let data = try secretStore.load(reference)
      guard let value = String(data: data, encoding: .utf8), !value.isEmpty else {
        throw ServiceDeepSeekHarnessMCPError.invalidStoredSecret
      }
      return value
    } catch SecretStoreError.notFound {
      throw ServiceDeepSeekHarnessMCPError.secretStoreUnavailable
    } catch let error as ServiceDeepSeekHarnessMCPError {
      throw error
    } catch {
      throw ServiceDeepSeekHarnessMCPError.secretStoreUnavailable
    }
  }

  func removeObsoleteSecrets(
    existing: ServiceDeepSeekHarnessMCPServerRecord,
    replacement: ServiceDeepSeekHarnessMCPServerRecord
  ) throws {
    let keptEnvironment = Set(replacement.environmentNames)
    let keptHeaders = Set(replacement.headerNames)
    for name in existing.environmentNames where !keptEnvironment.contains(name) {
      try removeSecret(serverID: existing.id, kind: "env", name: name)
    }
    for name in existing.headerNames where !keptHeaders.contains(name) {
      try removeSecret(serverID: existing.id, kind: "header", name: name)
    }
    if existing.transport != replacement.transport {
      for name in existing.environmentNames {
        try removeSecret(serverID: existing.id, kind: "env", name: name)
      }
      for name in existing.headerNames {
        try removeSecret(serverID: existing.id, kind: "header", name: name)
      }
    }
  }

  func removeSecrets(for record: ServiceDeepSeekHarnessMCPServerRecord) throws {
    for name in record.environmentNames {
      try removeSecret(serverID: record.id, kind: "env", name: name)
    }
    for name in record.headerNames {
      try removeSecret(serverID: record.id, kind: "header", name: name)
    }
  }

  func removeSecret(serverID: String, kind: String, name: String) throws {
    let reference = try secretReference(serverID: serverID, kind: kind, name: name)
    do {
      try secretStore.remove(reference)
    } catch SecretStoreError.notFound {
      return
    } catch {
      throw ServiceDeepSeekHarnessMCPError.secretStoreUnavailable
    }
  }

  func secretReference(serverID: String, kind: String, name: String) throws -> SecretReference {
    let seed = Data("dsh-mcp\0\(serverID)\0\(kind)\0\(name)".utf8)
    let digest = SHA256.hash(data: seed).map { String(format: "%02x", $0) }.joined()
    return try SecretReference(validating: "dsh-mcp.\(digest)")
  }

  static func isUnsafeTextScalar(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x09, 0x0A, 0x0D:
      false
    case 0..<0x20, 0x7F:
      true
    default:
      false
    }
  }

  static func isHTTPHeaderName(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x21, 0x23...0x27, 0x2A, 0x2B, 0x2D, 0x2E, 0x30...0x39,
      0x41...0x5A, 0x5E, 0x5F, 0x60, 0x61...0x7A, 0x7C, 0x7E:
      true
    default:
      false
    }
  }

}
