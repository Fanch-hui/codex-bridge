import Foundation

public enum ServiceApplicationMode: String, Codable, Sendable {
  case full
  case lite
}

extension ServiceSettings {
  public func applicationMode() async throws -> ServiceApplicationMode {
    guard let raw = try await string(for: .applicationMode) else { return .full }
    guard let mode = ServiceApplicationMode(rawValue: raw) else {
      throw ServiceStoreError.corruptRecord
    }
    return mode
  }

  public func setApplicationMode(_ mode: ServiceApplicationMode) async throws {
    try await set(mode.rawValue, for: .applicationMode)
  }
}
