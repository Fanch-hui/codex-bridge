import BridgeMCP
import BridgeSecurity
import BridgeServiceCore
import Foundation

enum WorkbenchProjectAccess {
  static func resolver(for project: ServiceProjectRecord) throws -> ProjectPathResolver {
    try project.root.validateCurrentIdentity()
    let root = try RegisteredRoot(
      capturing: URL(fileURLWithPath: project.root.canonicalPath, isDirectory: true))
    guard root.canonicalPath == project.root.canonicalPath,
      root.identity.inode == project.root.inode
    else { throw BridgeMCPQueryError.pathForbidden }
    return ProjectPathResolver(root: root)
  }
}
