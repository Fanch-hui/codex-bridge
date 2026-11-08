import BridgeAgentCore
import BridgeSecurity
import BridgeServiceCore
import Foundation

/// Owns immutable attachment bytes in the service's private workbench storage.
struct WorkbenchAttachmentStore {
  private let stagingLimit: Int64
  private let resolver: ProjectPathResolver
  private let writer = SecureProjectFileWriter(
    maximumBytes: AgentImageAttachmentLimits.maximumBytesPerAttachment)
  private let mutation = SecureProjectDirectoryMutation(
    maximumBytes: AgentImageAttachmentLimits.maximumBytesPerAttachment)

  init(root: RegisteredRoot, stagingLimit: Int64 = 100 * 1_024 * 1_024) {
    resolver = ProjectPathResolver(root: root)
    self.stagingLimit = stagingLimit
  }

  static func validatedID(_ id: String) throws -> String {
    guard id.utf8.count == 64,
      id.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
    else { throw ServiceStoreError.invalidArgument("workbench.attachment_reference") }
    return id
  }

  private func path(_ id: String, archived: Bool) throws -> SecureRelativePath {
    try SecureRelativePath((archived ? "Archive/" : "") + Self.validatedID(id) + ".image")
  }

  private func revision(_ id: String, archived: Bool) throws -> SecureFileRevision? {
    let value = try writer.revision(relativePath: path(id, archived: archived), through: resolver)
    guard value == nil || value?.sha256 == id else {
      throw ServiceStoreError.invalidArgument("workbench.attachment_reference")
    }
    return value
  }

  private func stagedBytes() throws -> Int64 {
    try resolver.root.validateCurrentIdentity()
    let rootURL = URL(fileURLWithPath: resolver.root.canonicalPath, isDirectory: true)
    return try FileManager.default.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil)
      .filter { $0.pathExtension == "image" }
      .reduce(Int64(0)) { count, url in
        let metadata = try FileSystemEntryMetadata(at: url)
        guard metadata.isRegularFile, !metadata.isSymbolicLink, let size = metadata.fileSize,
          size >= 0, Int64(size) <= stagingLimit - count
        else { throw ServiceStoreError.invalidArgument("workbench.attachment_storage_full") }
        return count + Int64(size)
      }
  }

  func stage(_ attachments: [(id: String, data: Data)]) throws {
    var unique = Set<String>()
    var missing: [(id: String, data: Data)] = []
    var extra: Int64 = 0
    for item in attachments where unique.insert(item.id).inserted {
      let staged = try revision(item.id, archived: false)
      let archived = try revision(item.id, archived: true)
      if staged == nil && archived == nil {
        missing.append(item)
        extra += Int64(item.data.count)
      }
    }
    guard extra <= stagingLimit - (try stagedBytes()) else {
      throw ServiceStoreError.invalidArgument("workbench.attachment_storage_full")
    }
    for item in missing {
      _ = try writer.write(
        relativePath: path(item.id, archived: false), through: resolver,
        mode: .create, content: item.data, expectedSHA256: nil, createParents: false,
        allowsBinaryContent: true)
    }
  }

  func read(_ id: String) throws -> (data: Data, mimeType: String) {
    let id = try Self.validatedID(id)
    for archived in [true, false] {
      if let data = try writer.readContent(
        relativePath: path(id, archived: archived), through: resolver)
      {
        guard SecureFileRevision.digest(of: data).sha256 == id else {
          throw ServiceStoreError.invalidArgument("workbench.attachment_reference")
        }
        return (data, try SecureProjectImageReader.mimeType(of: data))
      }
    }
    throw ServiceStoreError.invalidArgument("workbench.attachment_reference")
  }

  func archive(_ ids: [String]) throws {
    guard !ids.isEmpty else { return }
    try resolver.root.validateCurrentIdentity()
    let rootURL = URL(fileURLWithPath: resolver.root.canonicalPath, isDirectory: true)
    let archiveURL = rootURL.appendingPathComponent("Archive", isDirectory: true)
    if !FileManager.default.fileExists(atPath: archiveURL.path) {
      _ = try mutation.apply(
        action: .createDirectory, relativePath: SecureRelativePath("Archive"),
        destinationRelativePath: nil, through: resolver)
    }
    let metadata = try FileSystemEntryMetadata(at: archiveURL)
    guard metadata.isDirectory, !metadata.isSymbolicLink else {
      throw PathSecurityError.pathEscapeBlocked
    }
    var visited = Set<String>()
    for id in ids where visited.insert(id).inserted {
      let source = try path(id, archived: false)
      let destination = try path(id, archived: true)
      let staged = try revision(id, archived: false)
      let archived = try revision(id, archived: true)
      if archived != nil {
        if staged != nil {
          _ = try mutation.apply(
            action: .deleteFile(expectedSHA256: id), relativePath: source,
            destinationRelativePath: nil, through: resolver)
        }
      } else if staged != nil {
        _ = try mutation.apply(
          action: .moveFile(sourceExpectedSHA256: id, destinationExpectedAbsent: true),
          relativePath: source, destinationRelativePath: destination, through: resolver)
      } else {
        throw ServiceStoreError.invalidArgument("workbench.attachment_reference")
      }
    }
  }
}
