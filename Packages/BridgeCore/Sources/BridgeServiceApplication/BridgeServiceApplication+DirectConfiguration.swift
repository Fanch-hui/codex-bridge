import BridgeServiceCore
import Foundation

extension BridgeServiceApplication {
  func applyingDirectConfiguration(to project: ServiceProjectRecord) async throws
    -> ServiceProjectRecord
  {
    guard let configuration = try await settings.directConfiguration() else { return project }
    return try configuration.applying(to: project)
  }

  public func serviceDirectConfiguration(
    deadline: ContinuousClock.Instant
  ) async throws -> ServiceDirectConfiguration? {
    try Self.checkDeadline(deadline)
    return try await settings.directConfiguration()
  }

  public func serviceUpdateDirectConfiguration(
    _ configuration: ServiceDirectConfiguration,
    deadline: ContinuousClock.Instant
  ) async throws -> ServiceDirectConfiguration {
    try Self.checkDeadline(deadline)
    try await settings.setDirectConfiguration(configuration)
    return try await settings.directConfiguration() ?? ServiceDirectConfiguration()
  }
}
