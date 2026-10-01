import BridgeAgentCore
import Foundation

struct DeepSeekHarnessACPModelRoutes {
  struct Entry: Equatable, Sendable {
    let wireValue: String
    let modelID: String
    let displayName: String
    let modernRoute: Bool
  }

  static func decode(_ wireValue: String) -> (provider: String, model: String)? {
    guard let route = try? JSONDecoder().decode([String].self, from: Data(wireValue.utf8)),
      route.count == 2, !route[0].isEmpty, !route[1].isEmpty
    else { return nil }
    return (route[0], route[1])
  }

  static func catalog(from option: DeepSeekHarnessACPConfigOption) -> [Entry] {
    let counts = Dictionary(
      option.values.map { (decode($0.value)?.model ?? $0.value, 1) },
      uniquingKeysWith: +)
    var seen = Set<String>()
    return option.values.compactMap { value in
      guard seen.insert(value.value).inserted else { return nil }
      let route = decode(value.value)
      let model = route?.model ?? value.value
      return Entry(
        wireValue: value.value,
        modelID: counts[model, default: 0] > 1 ? value.value : model,
        displayName: value.name,
        modernRoute: route != nil)
    }
  }

  static func model(for selected: String, in catalog: [Entry]) -> Entry? {
    catalog.first { $0.modelID == selected || $0.wireValue == selected }
  }

  static func wireValue(for requested: String, option: DeepSeekHarnessACPConfigOption) throws
    -> String
  {
    let normalized =
      requested.hasPrefix("opencode-go/")
      ? String(requested.dropFirst("opencode-go/".count)) : requested
    guard let entry = model(for: normalized, in: catalog(from: option)) else {
      throw AgentRuntimeError.modelUnavailable(requested)
    }
    return entry.wireValue
  }
}

actor DeepSeekHarnessACPRemoteCatalogCache {
  private var catalogs: [String: [String]] = [:]

  private func key(installation: AgentInstallation, environment: [String: String]) -> String {
    [
      installation.id.rawValue, environment["DEEPSEEK_BASE_URL"] ?? "",
      environment["BRIDGE_DSH_PROTOCOL"] ?? "", environment["BRIDGE_DSH_CATALOG_BASE_URL"] ?? "",
    ]
    .joined(separator: "\n")
  }

  func models(installation: AgentInstallation, environment: [String: String]) -> [String]? {
    catalogs[key(installation: installation, environment: environment)]
  }

  func store(_ models: [String], installation: AgentInstallation, environment: [String: String]) {
    catalogs[key(installation: installation, environment: environment)] = models
  }
}
