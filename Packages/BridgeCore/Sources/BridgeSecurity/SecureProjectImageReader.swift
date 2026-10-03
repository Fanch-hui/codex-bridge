import BridgeAgentCore
import Foundation

public enum SecureProjectImageError: Error, Equatable, Sendable {
  case emptyImage
  case unsupportedImageFormat
  case changed(String)
}

public struct SecureProjectImageData: Equatable, Sendable {
  public let attachment: AgentImageAttachment
  public let data: Data

  public init(attachment: AgentImageAttachment, data: Data) {
    self.attachment = attachment
    self.data = data
  }
}

public enum SecureProjectImageReader {
  public static func capture(
    relativePaths: [String],
    through root: RegisteredRoot
  ) throws -> [SecureProjectImageData] {
    let paths = try relativePaths.map(SecureRelativePath.init)
    guard paths.count <= AgentImageAttachmentLimits.maximumCount,
      Set(paths.map(\.value)).count == paths.count
    else {
      throw AgentRuntimeError.invalidRequest("attachments.count")
    }

    let resolver = ProjectPathResolver(root: root)
    let reader = SecureProjectFileWriter(
      maximumBytes: AgentImageAttachmentLimits.maximumBytesPerAttachment
    )
    var totalBytes: Int64 = 0
    return try paths.map { path in
      guard let data = try reader.readContent(relativePath: path, through: resolver) else {
        throw PathSecurityError.pathDoesNotExist
      }
      let mimeType = try Self.mimeType(of: data)
      totalBytes += Int64(data.count)
      guard totalBytes <= AgentImageAttachmentLimits.maximumTotalBytes else {
        throw AgentRuntimeError.invalidRequest("attachments.totalSize")
      }
      let revision = SecureFileRevision.digest(of: data)
      let attachment = try AgentImageAttachment(
        relativePath: path.value,
        mimeType: mimeType,
        byteCount: Int64(revision.byteCount),
        sha256: revision.sha256
      )
      return SecureProjectImageData(attachment: attachment, data: data)
    }
  }

  public static func read(
    _ attachment: AgentImageAttachment,
    projectRoot: String
  ) throws -> SecureProjectImageData {
    let root = try RegisteredRoot(
      capturing: URL(fileURLWithPath: projectRoot, isDirectory: true)
    )
    let path = try SecureRelativePath(attachment.relativePath)
    let resolver = ProjectPathResolver(root: root)
    let reader = SecureProjectFileWriter(
      maximumBytes: AgentImageAttachmentLimits.maximumBytesPerAttachment
    )
    guard let data = try reader.readContent(relativePath: path, through: resolver) else {
      throw PathSecurityError.pathDoesNotExist
    }
    let mimeType = try Self.mimeType(of: data)
    let revision = SecureFileRevision.digest(of: data)
    guard Int64(data.count) == attachment.byteCount,
      revision.sha256 == attachment.sha256,
      mimeType == attachment.mimeType
    else {
      throw SecureProjectImageError.changed(attachment.relativePath)
    }
    return SecureProjectImageData(attachment: attachment, data: data)
  }

  private static func mimeType(of data: Data) throws -> String {
    let bytes = [UInt8](data.prefix(12))
    guard !bytes.isEmpty else { throw SecureProjectImageError.emptyImage }
    if bytes.starts(with: [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]) {
      return "image/png"
    }
    if bytes.starts(with: [0xff, 0xd8, 0xff]) {
      return "image/jpeg"
    }
    if bytes.count == 12,
      Array(bytes[0..<4]) == Array("RIFF".utf8),
      Array(bytes[8..<12]) == Array("WEBP".utf8)
    {
      return "image/webp"
    }
    throw SecureProjectImageError.unsupportedImageFormat
  }
}
