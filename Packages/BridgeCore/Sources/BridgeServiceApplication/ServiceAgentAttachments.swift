import BridgeAgentCore
import BridgeMCP
import BridgeSecurity
import BridgeServiceCore
import Foundation

enum ServiceAgentAttachments {
  static func capture(
    relativePaths: [String],
    project: ServiceProjectRecord,
    model: AgentModelDescriptor?
  ) throws -> [AgentImageAttachment] {
    guard !relativePaths.isEmpty else { return [] }
    guard model?.inputModalities?.contains(.image) == true else {
      throw BridgeMCPQueryError.contractRejected
    }

    let root = try registeredProjectRoot(project)
    return try SecureProjectImageReader.capture(
      relativePaths: relativePaths,
      through: root
    ).map(\.attachment)
  }

  static func captureForRestart(
    relativePaths: [String],
    originalAttachments: [AgentImageAttachment],
    project: ServiceProjectRecord,
    model: AgentModelDescriptor?
  ) throws -> [AgentImageAttachment] {
    guard relativePaths.count <= AgentImageAttachmentLimits.maximumCount,
      Set(relativePaths.map(pathKey)).count == relativePaths.count
    else {
      throw BridgeMCPQueryError.contractRejected
    }
    guard !relativePaths.isEmpty else { return [] }
    guard model?.inputModalities?.contains(.image) == true else {
      throw BridgeMCPQueryError.contractRejected
    }

    let root = try registeredProjectRoot(project)
    var originalsByPath: [String: AgentImageAttachment] = [:]
    for attachment in originalAttachments {
      let key = pathKey(attachment.relativePath)
      guard originalsByPath[key] == nil else {
        throw BridgeMCPQueryError.contractRejected
      }
      originalsByPath[key] = attachment
    }
    var preservedByPath: [String: AgentImageAttachment] = [:]
    var newPaths: [String] = []
    for relativePath in relativePaths {
      guard let original = originalsByPath[pathKey(relativePath)] else {
        newPaths.append(relativePath)
        continue
      }
      do {
        _ = try SecureProjectImageReader.read(original, projectRoot: root.canonicalPath)
      } catch {
        throw BridgeMCPQueryError.contractRejected
      }
      preservedByPath[relativePath] = original
    }

    let newlyCaptured = try capture(relativePaths: newPaths, project: project, model: model)
    let newAttachmentsByPath = Dictionary(
      uniqueKeysWithValues: newlyCaptured.map { ($0.relativePath, $0) }
    )
    let result = relativePaths.compactMap {
      preservedByPath[$0] ?? newAttachmentsByPath[$0]
    }
    guard result.count == relativePaths.count,
      result.reduce(Int64(0), { $0 + $1.byteCount })
        <= AgentImageAttachmentLimits.maximumTotalBytes
    else {
      throw BridgeMCPQueryError.contractRejected
    }
    return result
  }

  private static func registeredProjectRoot(_ project: ServiceProjectRecord) throws
    -> RegisteredRoot
  {
    let root = try RegisteredRoot(
      capturing: URL(fileURLWithPath: project.root.canonicalPath, isDirectory: true)
    )
    guard root.canonicalPath == project.root.canonicalPath,
      root.identity.device == project.root.device,
      root.identity.inode == project.root.inode
    else {
      throw BridgeMCPQueryError.contractRejected
    }
    return root
  }

  private static func pathKey(_ path: String) -> String {
    #if os(Windows)
      path.lowercased()
    #else
      path
    #endif
  }
}
