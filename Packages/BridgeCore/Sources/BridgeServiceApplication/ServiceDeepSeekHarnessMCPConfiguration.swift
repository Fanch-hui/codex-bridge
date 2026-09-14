import BridgeAgentCore
import BridgeSecurity
import BridgeServiceCore
import Foundation

public enum ServiceDeepSeekHarnessMCPError: Error, Equatable, LocalizedError, Sendable {
  case serverNotFound
  case secretStoreUnavailable
  case invalidStoredSecret

  public var errorDescription: String? {
    switch self {
    case .serverNotFound:
      "The DeepSeek Harness MCP server is unavailable."
    case .secretStoreUnavailable:
      "The DeepSeek Harness MCP credentials are unavailable."
    case .invalidStoredSecret:
      "The DeepSeek Harness MCP credentials are invalid."
    }
  }
}

private actor ServiceDeepSeekHarnessMCPMutationGate {
  private var occupied = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func acquire() async {
    if !occupied {
      occupied = true
      return
    }
    await withCheckedContinuation { continuation in
      waiters.append(continuation)
    }
  }

  func release() {
    guard let waiter = waiters.first else {
      occupied = false
      return
    }
    waiters.removeFirst()
    waiter.resume()
  }
}

/// Stores the global MCP definitions used by DeepSeek Harness. Metadata is
/// persisted in ServiceSettings; environment and header values remain in the
/// platform SecretStore and are resolved only for an Agent launch.
public actor ServiceDeepSeekHarnessMCPConfiguration {
  let settings: ServiceSettings
  let secretStore: any SecretStore
  private let mutationGate = ServiceDeepSeekHarnessMCPMutationGate()

  public init(settings: ServiceSettings, secretStore: any SecretStore) {
    self.settings = settings
    self.secretStore = secretStore
  }

  public func list() async throws -> [ServiceDeepSeekHarnessMCPServerSummary] {
    let records = try await settings.deepSeekHarnessMCPServers()
    var result: [ServiceDeepSeekHarnessMCPServerSummary] = []
    result.reserveCapacity(records.count)
    for record in records {
      result.append(try summary(for: record))
    }
    return result
  }

  public func save(
    _ input: ServiceDeepSeekHarnessMCPServerInput
  ) async throws -> ServiceDeepSeekHarnessMCPServerSummary {
    await mutationGate.acquire()
    do {
      let result = try await saveUnlocked(input)
      await mutationGate.release()
      return result
    } catch {
      await mutationGate.release()
      throw error
    }
  }

  private func saveUnlocked(
    _ input: ServiceDeepSeekHarnessMCPServerInput
  ) async throws -> ServiceDeepSeekHarnessMCPServerSummary {
    let records = try await settings.deepSeekHarnessMCPServers()
    let existing = records.first(where: { $0.id == input.id })
    if existing == nil, records.count >= 32 {
      throw ServiceStoreError.invalidArgument("dsh.mcp.servers")
    }
    guard records.filter({ $0.id == input.id }).count <= 1 else {
      throw ServiceStoreError.invalidArgument("dsh.mcp.id")
    }
    let record = try makeRecord(input, existingRecords: records)
    try storeProvidedSecrets(input)
    let updated = records.filter { $0.id != record.id } + [record]
    try await settings.setDeepSeekHarnessMCPServers(updated)
    if let existing {
      try removeObsoleteSecrets(existing: existing, replacement: record)
    }
    return try summary(for: record)
  }

  public func delete(id: String) async throws {
    await mutationGate.acquire()
    do {
      try await deleteUnlocked(id: id)
      await mutationGate.release()
    } catch {
      await mutationGate.release()
      throw error
    }
  }

  private func deleteUnlocked(id: String) async throws {
    let records = try await settings.deepSeekHarnessMCPServers()
    guard let record = records.first(where: { $0.id == id }) else {
      throw ServiceDeepSeekHarnessMCPError.serverNotFound
    }
    try await settings.setDeepSeekHarnessMCPServers(records.filter { $0.id != id })
    try removeSecrets(for: record)
  }

  public func enabledRuntimeConfigurations() async throws -> [AgentMCPServerConfiguration] {
    await mutationGate.acquire()
    do {
      let result = try await enabledRuntimeConfigurationsUnlocked()
      await mutationGate.release()
      return result
    } catch {
      await mutationGate.release()
      throw error
    }
  }

  private func enabledRuntimeConfigurationsUnlocked() async throws
    -> [AgentMCPServerConfiguration]
  {
    let records = try await settings.deepSeekHarnessMCPServers().filter(\.enabled)
    var result: [AgentMCPServerConfiguration] = []
    result.reserveCapacity(records.count)
    for record in records {
      let environment = try loadSecrets(for: record, kind: "env", names: record.environmentNames)
      let headers = try loadSecrets(for: record, kind: "header", names: record.headerNames)
      result.append(
        AgentMCPServerConfiguration(
          id: record.id,
          name: record.name,
          transport: record.transport,
          command: record.command,
          args: record.args,
          url: record.url,
          environment: environment,
          headers: headers
        )
      )
    }
    return result
  }
}
