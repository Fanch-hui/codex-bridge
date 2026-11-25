import BridgeACP
import BridgeIPC
import BridgeServiceCore
import Foundation

extension ServiceProviderGateway {
  package func call(_ request: IPCProviderGatewayRequest) async throws -> IPCProviderGatewayResponse
  {
    guard request.payloadJSON.utf8.count <= 2 * 1_024 * 1_024,
      let payload = try JSONDecoder().decode(
        ACPJSONValue.self, from: Data(request.payloadJSON.utf8)
      ).objectValue
    else { throw ServiceStoreError.invalidArgument("gateway.payload") }
    let result = try await command(request.action, payload: .object(payload))
    return IPCProviderGatewayResponse(
      resultJSON: String(decoding: try result.encodedData(), as: UTF8.self))
  }

  func command(_ action: String, payload: ACPJSONValue) async throws -> ACPJSONValue {
    guard let applicationMode, let externalApplications, let communityProviders else {
      throw ServiceStoreError.invalidArgument("gateway.not_initialized")
    }
    switch action {
    case "mode.status":
      let mode = try await applicationMode.status()
      return .object([
        "mode": .string(mode.mode.rawValue),
        "transition": mode.transition.map(ACPJSONValue.string) ?? .null,
        "error": (mode.error ?? serviceError).map(ACPJSONValue.string) ?? .null,
        "gateway": await serviceStatus(),
      ])
    case "status":
      let mode = try await applicationMode.status()
      let community = try await communityProviders.snapshot()
      return .object([
        "mode": .string(mode.mode.rawValue),
        "transition": mode.transition.map(ACPJSONValue.string) ?? .null,
        "error": (mode.error ?? serviceError).map(ACPJSONValue.string) ?? .null,
        "onboardingRequired": .bool(
          try await store.setting(key: "application.onboarding")?.value == "true"),
        "gateway": await serviceStatus(), "deadlines": deadlines.presentation,
        "providers": .array([]),
        "models": .array(models.map(\.presentation)),
        "plugins": community.plugins,
        "pluginOperation": community.operation,
        "communityModelsRefreshing": .bool(communityModelTask != nil),
        "communityModelError": communityModelError.map(ACPJSONValue.string) ?? .null,
        "clients": .array(try await externalApplications.clients()),
        "connections": .array(try await externalApplications.connections()),
        "activity": .array(Array(activeRequests.values) + (try await recentActivity())),
        "activityError": activityError.map(ACPJSONValue.string) ?? .null,
        "activitySummary": try await activitySummary(),
      ])
    case "service.setDeadlines":
      guard !savingDeadlines else { throw ServiceStoreError.storageBusy }
      savingDeadlines = true
      defer { savingDeadlines = false }
      let next = try GatewayDeadlineSettings(payload: payload)
      try await save(
        "gateway.deadlines", String(decoding: next.presentation.encodedData(), as: UTF8.self))
      deadlines = next
      return next.presentation
    case "service.setEnabled":
      guard let enabled = payload["enabled"]?.boolValue else {
        throw ServiceStoreError.invalidArgument("gateway.enabled")
      }
      try await setEnabled(enabled)
      return await serviceStatus()
    case "mode.set", "onboarding.complete":
      guard let raw = payload["mode"]?.stringValue,
        let mode = ServiceApplicationMode(rawValue: raw)
      else { throw ServiceStoreError.invalidArgument("application.mode") }
      _ = try await applicationMode.setMode(mode)
      if action == "onboarding.complete" { try await save("application.onboarding", "false") }
      return try await command("status", payload: .object([:]))
    case "mode.cancel":
      _ = try await applicationMode.cancel()
      return try await command("status", payload: .object([:]))
    case "models.refresh":
      if payload["communityOnly"]?.boolValue == true { return try await refreshCommunityModels() }
      return try await refreshModels()
    case "provider.call":
      guard let action = payload["action"]?.stringValue,
        Self.providerActions.contains(action)
      else { throw ServiceStoreError.invalidArgument("provider.action") }
      return try await existing.call(action, payload: payload["payload"] ?? .object([:]))
    default:
      if action.hasPrefix("plugins.") {
        let result = try await communityProviders.call(action: action, payload: payload)
        if [
          "plugins.install", "plugins.update", "plugins.enable", "plugins.remove", "plugins.apiKey",
          "plugins.callback", "plugins.signOut",
        ].contains(action),
          result["ok"]?.boolValue != false
        {
          invalidateCommunityModels()
        }
        return result
      }
      if action.hasPrefix("clients.") || action.hasPrefix("connections.") {
        return try await externalApplications.call(action: action, payload: payload)
      }
      throw ServiceStoreError.invalidArgument("gateway.action")
    }
  }

  private static let providerActions: Set<String> = [
    "status", "auth.status", "models.list", "models.discover",
    "settings.get", "settings.save", "settings.remove",
    "auth.begin", "auth.addAccount", "auth.cancel", "auth.signOut", "auth.refreshModels",
    "auth.switchAccount", "auth.removeAccount", "auth.setBackgroundAllowed",
    "connections.status", "connections.zcode", "connections.workbuddy",
    "configuration.status", "runtime.applyWhenIdle",
  ]
}
