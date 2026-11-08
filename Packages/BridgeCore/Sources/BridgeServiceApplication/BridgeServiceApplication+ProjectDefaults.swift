import BridgeServiceCore

extension BridgeServiceApplication {
  /// Project used when a request names none. This is Bridge's default workspace, never the
  /// project selected in the desktop sidebar. Nil only when no default workspace is configured.
  func defaultWorkspaceProjectID() async throws -> String? {
    guard let defaultWorkspace else { return nil }
    return try await defaultWorkspace.ensure().id.rawValue
  }

  public func serviceDefaultWorkspaceProjectID(
    deadline: ContinuousClock.Instant
  ) async throws -> String? {
    try Self.checkDeadline(deadline)
    return try await defaultWorkspaceProjectID()
  }

  func rejectDefaultWorkspaceRemoval(projectID: String) async throws {
    guard try await settings.string(for: .defaultWorkspaceProjectID) != projectID else {
      throw ServiceDefaultWorkspaceError.removalNotAllowed
    }
  }
}
