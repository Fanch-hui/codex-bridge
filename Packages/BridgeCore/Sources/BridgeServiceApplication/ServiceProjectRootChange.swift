import BridgeDomain
import BridgeMCP
import BridgeServiceCore
import Foundation

public struct ServiceProjectRootChange: Equatable, Sendable {
  public let path: String
  public let registeredDevice: String
  public let registeredInode: String
  public let currentDevice: String
  public let currentInode: String
  public let canRebind: Bool

  public init(
    path: String, registeredDevice: String, registeredInode: String,
    currentDevice: String, currentInode: String, canRebind: Bool
  ) {
    self.path = path
    self.registeredDevice = registeredDevice
    self.registeredInode = registeredInode
    self.currentDevice = currentDevice
    self.currentInode = currentInode
    self.canRebind = canRebind
  }

  static func inspect(_ root: ServiceRootIdentity, current: ServiceRootIdentity) -> Self? {
    guard !root.matches(current) else { return nil }
    return Self(
      path: root.canonicalPath,
      registeredDevice: String(root.device), registeredInode: String(root.inode),
      currentDevice: String(current.device), currentInode: String(current.inode),
      canRebind: root.isDeviceOnlyChange(to: current))
  }

  static func inspect(_ root: ServiceRootIdentity) -> Self? {
    guard
      let current = try? ServiceRootIdentity(
        capturing: URL(fileURLWithPath: root.canonicalPath, isDirectory: true))
    else { return nil }
    return inspect(root, current: current)
  }

}

extension BridgeServiceApplication {
  public func serviceConfirmProjectRootChange(
    projectID: String, presented: ServiceProjectRootChange, deadline: ContinuousClock.Instant
  ) async throws {
    try Self.checkDeadline(deadline)
    guard projectID != (try await defaultWorkspaceProjectID()),
      let project = try await projects.projects().first(where: { $0.id.rawValue == projectID })
    else { throw BridgeMCPQueryError.projectNotFound }
    let lease = try await acquireDirectLease(
      project: project, owner: .projectRootRebind(operationID: UUID().uuidString))
    do {
      try Self.checkDeadline(deadline)
      guard presented.canRebind,
        let current = try? ServiceRootIdentity(
          capturing: URL(fileURLWithPath: project.root.canonicalPath, isDirectory: true)),
        ServiceProjectRootChange.inspect(project.root, current: current) == presented,
        project.root.isDeviceOnlyChange(to: current)
      else { throw BridgeMCPQueryError.projectRootIdentityChanged }
      try await projects.confirmRootDeviceChange(
        projectID: project.id, expected: project.root, replacement: current)
      await lease.release()
    } catch {
      await lease.release()
      throw error
    }
  }
}
