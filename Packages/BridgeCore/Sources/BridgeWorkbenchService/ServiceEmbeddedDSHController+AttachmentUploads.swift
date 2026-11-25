import BridgeACP
import BridgeAgentCore
import BridgeSecurity
import BridgeServiceCore
import Foundation

struct WorkbenchAttachmentUpload: Sendable {
  let metadata: [ACPJSONValue]
  var buffers: [Data]
  var updatedAt: Date
}

extension ServiceEmbeddedDSHController {
  func attachmentAction(_ action: String, payload: [String: ACPJSONValue]) throws -> ACPJSONValue {
    attachmentUploads = attachmentUploads.filter {
      Date().timeIntervalSince($0.value.updatedAt) < 600
    }
    switch action {
    case "attachments.import": return try importAttachments(payload)
    case "attachments.import.begin":
      guard let items = payload["items"]?.arrayValue, !items.isEmpty,
        items.count <= AgentImageAttachmentLimits.maximumCount, attachmentUploads.count < 3
      else { throw ServiceStoreError.invalidArgument("workbench.attachment_upload") }
      var total = 0
      for item in items {
        guard let count = item["byteCount"]?.intValue, count > 0,
          count <= AgentImageAttachmentLimits.maximumBytesPerAttachment,
          let mime = item["mimeType"]?.stringValue,
          AgentImageAttachmentLimits.supportedMIMETypes.contains(mime)
        else { throw ServiceStoreError.invalidArgument("workbench.attachment_upload") }
        total += count
      }
      guard total <= AgentImageAttachmentLimits.maximumTotalBytes else {
        throw ServiceStoreError.invalidArgument("workbench.attachment_size")
      }
      let id = UUID().uuidString
      attachmentUploads[id] = WorkbenchAttachmentUpload(
        metadata: items,
        buffers: items.map { _ in Data() }, updatedAt: Date())
      return .object(["uploadID": .string(id)])
    case "attachments.import.append":
      let id = try Self.requiredString(payload, "uploadID")
      guard var upload = attachmentUploads[id], let index = payload["index"]?.intValue,
        upload.buffers.indices.contains(index), let offset = payload["offset"]?.intValue,
        let encoded = payload["data"]?.stringValue, encoded.utf8.count <= 720 * 1_024,
        let data = Data(base64Encoded: encoded), !data.isEmpty, data.count <= 512 * 1_024,
        let expected = upload.metadata[index]["byteCount"]?.intValue,
        offset >= 0, offset <= expected, data.count <= expected - offset
      else { throw ServiceStoreError.invalidArgument("workbench.attachment_chunk") }
      if offset == upload.buffers[index].count {
        upload.buffers[index].append(data)
      } else {
        guard offset + data.count <= upload.buffers[index].count,
          upload.buffers[index].subdata(in: offset..<(offset + data.count)) == data
        else { throw ServiceStoreError.invalidArgument("workbench.attachment_offset") }
      }
      upload.updatedAt = Date()
      attachmentUploads[id] = upload
      return .object(["nextOffset": .integer(Int64(upload.buffers[index].count))])
    case "attachments.import.finish":
      let id = try Self.requiredString(payload, "uploadID")
      guard let upload = attachmentUploads[id] else {
        throw ServiceStoreError.invalidArgument("workbench.attachment_upload")
      }
      let items = try upload.metadata.enumerated().map { index, item -> ACPJSONValue in
        guard item["byteCount"]?.intValue == upload.buffers[index].count else {
          throw ServiceStoreError.invalidArgument("workbench.attachment_incomplete")
        }
        return .object([
          "name": item["name"] ?? .string("图片"),
          "data": .string(upload.buffers[index].base64EncodedString()),
        ])
      }
      let result = try importAttachments(["items": .array(items)])
      attachmentUploads.removeValue(forKey: id)
      return result
    case "attachments.import.cancel":
      attachmentUploads.removeValue(forKey: try Self.requiredString(payload, "uploadID"))
      return .object(["cancelled": .bool(true)])
    case "attachments.read":
      let id = try Self.requiredString(payload, "id")
      let (data, mimeType) = try WorkbenchAttachmentStore(root: attachmentRoot()).read(id)
      let offset = max(0, payload["offset"]?.intValue ?? 0)
      guard offset <= data.count else {
        throw ServiceStoreError.invalidArgument("workbench.attachment_offset")
      }
      let count = min(65_536, max(1, payload["limit"]?.intValue ?? 65_536))
      let next = min(offset + count, data.count)
      return .object([
        "data": .string(data.subdata(in: offset..<next).base64EncodedString()),
        "offset": .integer(Int64(offset)),
        "nextOffset": next < data.count ? .integer(Int64(next)) : .null,
        "totalBytes": .integer(Int64(data.count)), "mimeType": .string(mimeType),
      ])
    default: throw ServiceStoreError.invalidArgument("workbench.attachment_action")
    }
  }

  func freezePromptAttachments(_ payload: [String: ACPJSONValue], sessionID: String) async throws
    -> [String: ACPJSONValue]
  {
    var frozen = payload
    let paths = payload["attachmentPaths"]?.arrayValue?.compactMap(\.stringValue) ?? []
    guard !paths.isEmpty else { return frozen }
    let project = try await project(for: sessionID)
    let root = try RegisteredRoot(capturing: URL(fileURLWithPath: project.root.canonicalPath))
    let images = try SecureProjectImageReader.capture(relativePaths: paths, through: root)
    let imported = try importAttachments([
      "items": .array(
        images.map { image in
          .object([
            "name": .string(image.attachment.relativePath),
            "data": .string(image.data.base64EncodedString()),
          ])
        })
    ])
    frozen["attachmentRefs"] = .array(
      (payload["attachmentRefs"]?.arrayValue ?? [])
        + (imported["attachmentRefs"]?.arrayValue ?? []))
    frozen.removeValue(forKey: "attachmentPaths")
    return frozen
  }
}
