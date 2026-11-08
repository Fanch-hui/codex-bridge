import BridgeServiceCore
import Foundation

public enum ServiceDefaultWorkspaceError: Error, Equatable, LocalizedError, Sendable {
  case removalNotAllowed

  public var errorDescription: String? {
    switch self {
    case .removalNotAllowed: "默认工作区不能移除。"
    }
  }
}

/// A Bridge-owned directory registered as a project. Conversations without a chosen project and
/// MCP requests that name none work here, independent of the project selected in the sidebar.
public actor ServiceDefaultWorkspace {
  public static let projectName = "默认工作区"

  private let rootURL: URL
  private let projects: ServiceProjectService
  private let settings: ServiceSettings
  private let prepareDirectory: @Sendable () throws -> Void
  private var inFlight: Task<ServiceProjectRecord, Error>?

  /// `prepareDirectory` must create (or securely verify) the directory at `rootURL`.
  public init(
    rootURL: URL,
    projects: ServiceProjectService,
    settings: ServiceSettings,
    prepareDirectory: (@Sendable () throws -> Void)? = nil
  ) {
    self.rootURL = rootURL
    self.projects = projects
    self.settings = settings
    self.prepareDirectory =
      prepareDirectory ?? {
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
      }
  }

  /// Returns the registered default workspace, creating or repairing the directory, the project
  /// registration and the persisted project ID when any of them is missing or stale.
  public func ensure() async throws -> ServiceProjectRecord {
    if let inFlight { return try await inFlight.value }
    let task = Task { try await self.reconcile() }
    inFlight = task
    defer { inFlight = nil }
    return try await task.value
  }

  private func reconcile() async throws -> ServiceProjectRecord {
    try prepareDirectory()
    let current = try ServiceRootIdentity(capturing: rootURL)
    let storedID = try await settings.string(for: .defaultWorkspaceProjectID)
    let registered = try await projects.projects()
    // A project already at this directory wins; otherwise the persisted ID keeps its history
    // when the directory was lost and recreated or the data root moved.
    let candidate =
      registered.first { $0.root.canonicalPath == current.canonicalPath }
      ?? registered.first { $0.id.rawValue == storedID }
    guard var record = candidate else {
      let created = try await projects.register(name: Self.projectName, rootURL: rootURL)
      try await settings.set(created.id.rawValue, for: .defaultWorkspaceProjectID)
      return created
    }
    if !Self.isCurrent(record.root, matching: current) {
      try await projects.rebindRoot(
        projectID: record.id, expected: record.root, replacement: current)
      guard let rebound = try await projects.project(id: record.id) else {
        throw ServiceStoreError.unknownProject(record.id)
      }
      record = rebound
    }
    if storedID != record.id.rawValue {
      try await settings.set(record.id.rawValue, for: .defaultWorkspaceProjectID)
    }
    return record
  }

  private static func isCurrent(
    _ root: ServiceRootIdentity, matching current: ServiceRootIdentity
  ) -> Bool {
    root.canonicalPath == current.canonicalPath && (try? root.validateCurrentIdentity()) != nil
  }
}
