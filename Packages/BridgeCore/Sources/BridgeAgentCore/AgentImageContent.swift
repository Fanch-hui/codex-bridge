import Foundation

/// Immutable image input captured by the service before entering a private workspace.
public struct AgentImageContent: Equatable, Sendable {
  public let attachment: AgentImageAttachment
  public let data: Data

  public init(attachment: AgentImageAttachment, data: Data) throws {
    guard Int64(data.count) == attachment.byteCount else {
      throw AgentRuntimeError.invalidRequest("attachment.content")
    }
    self.attachment = attachment
    self.data = data
  }
}
