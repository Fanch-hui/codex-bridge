import Foundation

extension ServiceSettings {
  public func qwenStudioEnabled() async throws -> Bool {
    guard let value = try await string(for: .qwenStudioEnabled) else { return false }
    guard let enabled = Bool(value) else { throw ServiceStoreError.corruptRecord }
    return enabled
  }

  public func setQwenStudioEnabled(_ enabled: Bool) async throws {
    try await set(String(enabled), for: .qwenStudioEnabled)
  }

  public func qwenStudioExposureMode() async throws -> ServiceMCPExposureMode {
    guard let value = try await string(for: .qwenStudioExposureMode) else { return .full }
    guard let mode = ServiceMCPExposureMode(rawValue: value) else {
      throw ServiceStoreError.corruptRecord
    }
    return mode
  }

  public func setQwenStudioExposureMode(_ mode: ServiceMCPExposureMode) async throws {
    try await set(mode.rawValue, for: .qwenStudioExposureMode)
  }

  public func geminiEnabled() async throws -> Bool {
    guard let value = try await string(for: .geminiEnabled) else { return false }
    guard let enabled = Bool(value) else { throw ServiceStoreError.corruptRecord }
    return enabled
  }

  public func setGeminiEnabled(_ enabled: Bool) async throws {
    try await set(String(enabled), for: .geminiEnabled)
  }

  public func geminiExposureMode() async throws -> ServiceMCPExposureMode {
    guard let value = try await string(for: .geminiExposureMode) else { return .full }
    guard let mode = ServiceMCPExposureMode(rawValue: value) else {
      throw ServiceStoreError.corruptRecord
    }
    return mode
  }

  public func setGeminiExposureMode(_ mode: ServiceMCPExposureMode) async throws {
    try await set(mode.rawValue, for: .geminiExposureMode)
  }

}
