import BridgeACP
import BridgeAgentCore
import BridgeSecurity
import BridgeServiceCore
import Foundation

extension ServiceEmbeddedDSHController {
  func importAttachments(_ payload: [String: ACPJSONValue]) throws -> ACPJSONValue {
    guard let items = payload["items"]?.arrayValue,
      !items.isEmpty, items.count <= AgentImageAttachmentLimits.maximumCount
    else { throw ServiceStoreError.invalidArgument("workbench.attachments") }
    var result: [ACPJSONValue] = []
    var total = 0
    var additions: [(String, Data, String, String)] = []
    for item in items {
      guard let encoded = item["data"]?.stringValue,
        encoded.utf8.count <= 12 * 1_024 * 1_024,
        let bytes = Data(base64Encoded: encoded), !bytes.isEmpty
      else { throw ServiceStoreError.invalidArgument("workbench.attachment_data") }
      let mime = try SecureProjectImageReader.mimeType(of: bytes)
      total += bytes.count
      guard total <= AgentImageAttachmentLimits.maximumTotalBytes else {
        throw ServiceStoreError.invalidArgument("workbench.attachment_size")
      }
      let id = SecureFileRevision.digest(of: bytes).sha256
      let name = String((item["name"]?.stringValue ?? "图片").prefix(256))
      additions.append((id, bytes, mime, name))
    }
    try WorkbenchAttachmentStore(root: attachmentRoot()).stage(
      additions.map { (id: $0.0, data: $0.1) })
    for (id, bytes, mime, name) in additions {
      var item: [String: ACPJSONValue] = [
        "id": .string(id), "name": .string(name), "mimeType": .string(mime),
        "byteCount": .integer(Int64(bytes.count)),
      ]
      if bytes.count <= 256 * 1_024 {
        item["previewDataURL"] = .string("data:\(mime);base64,\(bytes.base64EncodedString())")
      }
      result.append(.object(item))
    }
    return .object([
      "attachmentRefs": .array(additions.map { .string($0.0) }), "items": .array(result),
    ])
  }

  func attachmentRoot() throws -> RegisteredRoot {
    let directory = dataRoot.appendingPathComponent("WorkbenchAttachments", isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    return try RegisteredRoot(capturing: directory)
  }

  func attachmentContent(_ references: [ACPJSONValue]) throws -> [ACPJSONValue] {
    guard references.count <= AgentImageAttachmentLimits.maximumCount else {
      throw ServiceStoreError.invalidArgument("workbench.attachments")
    }
    let storage = WorkbenchAttachmentStore(root: try attachmentRoot())
    var total = 0
    return try references.map { reference in
      guard let id = reference.stringValue else {
        throw ServiceStoreError.invalidArgument("workbench.attachment_reference")
      }
      let (data, mimeType) = try storage.read(id)
      total += data.count
      guard total <= AgentImageAttachmentLimits.maximumTotalBytes else {
        throw ServiceStoreError.invalidArgument("workbench.attachment_size")
      }
      return .object([
        "type": .string("image"),
        "mediaType": .string(mimeType),
        "data": .string(data.base64EncodedString()),
      ])
    }
  }

  func archiveAcceptedAttachments(_ references: [ACPJSONValue]) throws {
    guard references.count <= AgentImageAttachmentLimits.maximumCount else {
      throw ServiceStoreError.invalidArgument("workbench.attachments")
    }
    let ids = try references.map { reference in
      guard let id = reference.stringValue else {
        throw ServiceStoreError.invalidArgument("workbench.attachment_reference")
      }
      return try WorkbenchAttachmentStore.validatedID(id)
    }
    try WorkbenchAttachmentStore(root: attachmentRoot()).archive(ids)
  }
}
