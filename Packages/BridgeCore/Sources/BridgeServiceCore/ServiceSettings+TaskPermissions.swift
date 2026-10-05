extension ServiceSettings {
  func taskPermissionMode(for key: ServiceSettingKey) async throws -> ServicePermissionMode {
    guard let value = try await string(for: key) else { return .full }
    guard let mode = Self.savedPermissionMode(value) else {
      throw ServiceStoreError.corruptRecord
    }
    return mode
  }

  func setTaskPermissionMode(_ value: String, for key: ServiceSettingKey) async throws {
    guard let mode = Self.savedPermissionMode(value) else {
      throw ServiceStoreError.invalidArgument(key.rawValue)
    }
    try await set(mode.rawValue, for: key)
  }

  private static func savedPermissionMode(_ value: String) -> ServicePermissionMode? {
    switch value {
    case "plan": .readOnly
    case "build": .full
    default: ServicePermissionMode(rawValue: value)
    }
  }
}
