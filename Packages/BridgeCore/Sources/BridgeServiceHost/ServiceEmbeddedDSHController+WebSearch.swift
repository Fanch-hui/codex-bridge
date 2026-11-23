import BridgeACP
import BridgeServiceCore

extension ServiceEmbeddedDSHController {
  func workbenchSearchSettings(_ action: String, input: ACPJSONValue) async throws -> ACPJSONValue {
    switch action {
    case "search.settings.get": return try await workbenchSearch.settings()
    case "search.settings.save": return try await workbenchSearch.save(input)
    case "search.settings.remove": return try await workbenchSearch.remove()
    default: throw ServiceStoreError.invalidArgument("workbench.search_settings_action")
    }
  }

  func workbenchSearchCallback(_ input: ACPJSONValue) async throws -> ACPJSONValue {
    switch input["operation"]?.stringValue {
    case "settings":
      let settings = try await workbenchSearch.settings()
      return .object(["provider": settings["provider"] ?? .null])
    case "search":
      try await requireWorkbenchEnabled()
      return try await workbenchSearch.search(input)
    default:
      throw ServiceStoreError.invalidArgument("workbench.search_operation")
    }
  }
}
