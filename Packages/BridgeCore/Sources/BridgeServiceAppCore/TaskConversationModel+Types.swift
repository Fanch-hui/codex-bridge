import BridgeAgentCore
import BridgeIPC

extension TaskConversationModel {
  public enum Activity: Equatable {
    case idle
    case thinking
    case executing(String?)
    case responding
  }

  public struct Entry: Identifiable, Equatable {
    public let key: String
    public let role: String
    public let kind: String
    public let messageID: Int64?
    public var content: String
    public var toolName: String?
    public var toolStatus: String?
    public var toolArguments: String?
    public var isFinal: Bool

    public var id: String { key }

    public var displayToolArguments: String? {
      guard let envelope = AgentToolArgumentsEnvelope.decode(toolArguments) else {
        return toolArguments
      }
      return envelope.arguments
    }

    public var displayContent: String {
      guard kind == "tool_call",
        AgentToolArgumentsEnvelope.decode(toolArguments)?.contentIsOutput != true,
        let arguments = displayToolArguments
      else {
        return content
      }
      return Self.removeLegacyToolArgumentPrefix(
        from: content,
        arguments: arguments
      )
    }

    public var childRuns: [AgentChildRun] {
      AgentToolArgumentsEnvelope.decode(toolArguments)?.childRuns ?? []
    }

    public init(
      _ message: IPCTaskConversationMessage,
      isFinal: Bool,
      keyPrefix: String? = nil
    ) {
      key = keyPrefix.map { "\($0):\(message.key)" } ?? message.key
      role = message.role
      kind = message.kind
      messageID = message.messageID
      content = message.content
      toolName = message.toolName
      toolStatus = message.toolStatus
      toolArguments = message.toolArguments
      self.isFinal = isFinal
    }

    public func prefixed(for taskID: String) -> Self {
      Self(
        IPCTaskConversationMessage(
          messageID: messageID, key: key, role: role, kind: kind, content: content,
          toolName: toolName, toolStatus: toolStatus, toolArguments: toolArguments
        ), isFinal: true, keyPrefix: taskID
      )
    }

    public init(key: String, role: String, kind: String, content: String, isFinal: Bool) {
      self.key = key
      self.role = role
      self.kind = kind
      messageID = nil
      self.content = content
      toolName = nil
      toolStatus = nil
      toolArguments = nil
      self.isFinal = isFinal
    }

    private static func removeLegacyToolArgumentPrefix(
      from content: String,
      arguments: String
    ) -> String {
      guard !arguments.isEmpty, content.hasPrefix(arguments) else { return content }
      let suffix = content.dropFirst(arguments.count)
      if suffix.isEmpty {
        return ""
      }
      if suffix.hasPrefix("\r\n") {
        return String(suffix.dropFirst(2))
      }
      if suffix.first == "\n" {
        return String(suffix.dropFirst())
      }
      return content
    }
  }
}
