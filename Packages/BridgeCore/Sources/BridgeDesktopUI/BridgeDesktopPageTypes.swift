import Foundation

public struct BridgeDesktopActivityRow: Codable, Equatable, Sendable {
  public let id: String
  public let sequence: Int64
  public let kind: String
  public let summary: String
  public let occurredAt: String

  public init(
    id: String,
    sequence: Int64,
    kind: String,
    summary: String,
    occurredAt: String
  ) {
    self.id = id
    self.sequence = sequence
    self.kind = kind
    self.summary = summary
    self.occurredAt = occurredAt
  }
}

public struct BridgeDesktopConversationEntry: Codable, Equatable, Sendable {
  public let id: String
  public let role: String
  public let text: String
  public let status: String?

  public init(id: String, role: String, text: String, status: String? = nil) {
    self.id = id
    self.role = role
    self.text = text
    self.status = status
  }
}

public struct BridgeDesktopBrowserSlot: Codable, Equatable, Sendable {
  public let visible: Bool
  public let enabled: Bool
  public let status: String
  public let canToggle: Bool
  public let canOpenExternally: Bool
  public let canGoBack: Bool
  public let canGoForward: Bool
  public let canReload: Bool
  public let canLoadEarlierConversation: Bool

  public init(
    visible: Bool = true,
    enabled: Bool = true,
    status: String = "由宿主加载 ChatGPT 工作区",
    canToggle: Bool = true,
    canOpenExternally: Bool = false,
    canGoBack: Bool = false,
    canGoForward: Bool = false,
    canReload: Bool = true,
    canLoadEarlierConversation: Bool = false
  ) {
    self.visible = visible
    self.enabled = enabled
    self.status = status
    self.canToggle = canToggle
    self.canOpenExternally = canOpenExternally
    self.canGoBack = canGoBack
    self.canGoForward = canGoForward
    self.canReload = canReload
    self.canLoadEarlierConversation = canLoadEarlierConversation
  }
}

public struct BridgeDesktopBrowserViewport: Codable, Equatable, Sendable {
  public let x: Double
  public let y: Double
  public let width: Double
  public let height: Double
  public let visible: Bool

  public init(x: Double, y: Double, width: Double, height: Double, visible: Bool) {
    self.x = x
    self.y = y
    self.width = width
    self.height = height
    self.visible = visible
  }
}

public struct BridgeDesktopSettingOption: Codable, Equatable, Sendable {
  public let id: String
  public let title: String
  public let detail: String?

  public init(id: String, title: String, detail: String? = nil) {
    self.id = id
    self.title = title
    self.detail = detail
  }
}
