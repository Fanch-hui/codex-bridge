import BridgeACP
import BridgeSecurity
import BridgeServiceCore
import Foundation

private struct CommunityUpdateCheck: Codable, Sendable {
  let version: String
  let checkedAt: Date
}

extension ServiceCommunityProviders {
  func checkUpdate(payload: ACPJSONValue) async throws -> ACPJSONValue {
    try beginRequest()
    defer { endRequest() }
    guard let id = payload["id"]?.stringValue,
      let plugin = try await records().first(where: { $0.id == id && $0.isInstalled })
    else { throw ServiceCommunityProviderError.pluginMissing }
    let checking: Task<String, any Error>
    let ownsCheck: Bool
    if let existing = updateChecks[id] {
      checking = existing
      ownsCheck = false
    } else {
      let force = payload["force"]?.boolValue == true
      checking = Task { try await self.latestVersion(for: plugin, force: force) }
      ownsCheck = true
      updateChecks[id] = checking
    }
    defer { if ownsCheck { updateChecks.removeValue(forKey: id) } }
    let latest = try await checking.value
    try Task.checkCancellation()
    return .object(["version": .string(latest), "installed": .string(plugin.version)])
  }

  private func latestVersion(for plugin: Plugin, force: Bool) async throws -> String {
    let key = "providers.community.update.\(plugin.id)"
    if !force, let stored = try await store.setting(key: key)?.value {
      let cached = try JSONDecoder().decode(CommunityUpdateCheck.self, from: Data(stored.utf8))
      if Calendar.current.isDateInToday(cached.checkedAt) { return cached.version }
    }
    let (_, installer) = try await runtime()
    let version = try await installer.latestVersion(name: plugin.package)
    let check = CommunityUpdateCheck(version: version, checkedAt: Date())
    let encoded = try JSONEncoder().encode(check)
    try await store.setSetting(
      ServiceSettingRecord(
        key: key, value: String(decoding: encoded, as: UTF8.self), updatedAt: Date()))
    return version
  }

  func usage(payload: ACPJSONValue) async throws -> ACPJSONValue {
    try beginRequest()
    defer { endRequest() }
    guard let id = payload["id"]?.stringValue, let provider = payload["provider"]?.stringValue,
      let plugin = try await records().first(where: { $0.id == id && $0.isInstalled }),
      plugin.providers.contains(provider)
    else { throw ServiceCommunityProviderError.pluginMissing }
    let client = try await sharedHost()
    let response = try await request(
      client, method: "providerSummary", params: .object(["provider": .string(provider)]))
    guard let accounts = response["accounts"]?.arrayValue else {
      throw ServiceCommunityProviderError.invalidRequest
    }
    guard response["usage"]?.boolValue == true else {
      return .object(["available": .bool(false), "accounts": .array([])])
    }
    var result: [ACPJSONValue] = []
    for (index, account) in accounts.enumerated() {
      guard let key = account["key"]?.stringValue, !key.isEmpty else {
        throw ServiceCommunityProviderError.invalidRequest
      }
      do {
        let value = try await request(
          client, method: "usage",
          params: .object(["provider": .string(provider), "account": .string(key)]))
        var item = Self.usagePresentation(value)
        item["index"] = .integer(Int64(index + 1))
        result.append(.object(item))
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        result.append(.object(["index": .integer(Int64(index + 1)), "error": .bool(true)]))
      }
    }
    return .object(["available": .bool(true), "accounts": .array(result)])
  }

  private static func usagePresentation(_ value: ACPJSONValue) -> [String: ACPJSONValue] {
    var result: [String: ACPJSONValue] = [:]
    if let error = value["error"]?.stringValue, !error.isEmpty { result["error"] = .bool(true) }
    for name in ["plan", "until", "balance"] {
      if let text = value[name]?.stringValue, !text.isEmpty {
        result[name] = .string(OutboundContentSecurity.redactedSecrets(text, maximumUTF8Bytes: 256))
      }
    }
    result["windows"] = .array(
      (value["windows"]?.arrayValue ?? []).map { window in
        var fields: [String: ACPJSONValue] = [:]
        for name in ["name", "display", "unit", "resetsAt", "runsOutAt", "model", "family", "pool"]
        {
          if let text = window[name]?.stringValue, !text.isEmpty {
            fields[name] = .string(
              OutboundContentSecurity.redactedSecrets(text, maximumUTF8Bytes: 256))
          }
        }
        for name in ["used", "balance", "amount", "limit"] {
          if let number = window[name]?.doubleValue, number.isFinite, number >= 0 {
            fields[name] = .number(number)
          }
        }
        return .object(fields)
      })
    return result
  }
}
