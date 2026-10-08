import BridgeACP
import BridgeAgentCore
import BridgeSecurity
import Foundation

public struct DeepSeekHarnessACPImageInput: Sendable {
  let mimeType: String
  let data: Data

  static func capture(
    _ attachments: [AgentImageAttachment],
    projectRoot: String,
    supportsImagePrompt: Bool
  ) throws -> [Self] {
    guard !attachments.isEmpty else { return [] }
    guard supportsImagePrompt else {
      throw AgentRuntimeError.invalidRequest("deepseek_harness.model_image_input_unsupported")
    }
    guard attachments.count <= AgentImageAttachmentLimits.maximumCount,
      attachments.reduce(Int64(0), { $0 + $1.byteCount })
        <= AgentImageAttachmentLimits.maximumTotalBytes
    else { throw AgentRuntimeError.invalidRequest("request.attachments") }
    return try attachments.map { attachment in
      let verified = try SecureProjectImageReader.read(attachment, projectRoot: projectRoot)
      return Self(mimeType: verified.attachment.mimeType, data: verified.data)
    }
  }

  var block: ACPJSONValue {
    .object([
      "type": .string("image"),
      "mimeType": .string(mimeType),
      "data": .string(data.base64EncodedString()),
    ])
  }
}
