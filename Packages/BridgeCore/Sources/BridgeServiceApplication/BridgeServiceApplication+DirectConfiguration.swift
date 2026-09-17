import BridgeServiceCore

extension BridgeServiceApplication {
  func applyingDirectConfiguration(to project: ServiceProjectRecord) async throws
    -> ServiceProjectRecord
  {
    guard let configuration = try await settings.directConfiguration() else { return project }
    return try configuration.applying(to: project)
  }
}
