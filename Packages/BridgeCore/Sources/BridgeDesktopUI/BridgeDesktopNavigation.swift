import Foundation

public enum BridgeDesktopNavigation: String, Codable, CaseIterable, Identifiable, Sendable {
  case overview
  case workbench
  case projects
  case logs
  case connections
  case settings

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .overview: "概览"
    case .workbench: "工作台"
    case .projects: "项目"
    case .logs: "日志"
    case .connections: "连接"
    case .settings: "设置"
    }
  }

  public var symbol: String {
    switch self {
    case .overview: "gauge.with.needle"
    case .workbench: "bubble.left.and.text.bubble.right.fill"
    case .projects: "folder.fill"
    case .logs: "list.dash.header.rectangle"
    case .connections: "point.3.connected.trianglepath.dotted"
    case .settings: "gearshape"
    }
  }

  public static var canonicalItems: [BridgeDesktopNavigationItem] {
    allCases.map { BridgeDesktopNavigationItem(navigation: $0) }
  }
}

public struct BridgeDesktopNavigationItem: Codable, Equatable, Sendable {
  public let navigation: BridgeDesktopNavigation
  public let title: String
  public let symbol: String
  public let badge: Int?

  public init(
    navigation: BridgeDesktopNavigation,
    title: String? = nil,
    symbol: String? = nil,
    badge: Int? = nil
  ) {
    self.navigation = navigation
    self.title = title ?? navigation.title
    self.symbol = symbol ?? navigation.symbol
    self.badge = badge
  }
}

public enum BridgeDesktopStatusTone: String, Codable, Sendable {
  case neutral
  case running
  case success
  case warning
  case error
}

public struct BridgeDesktopPageHeader: Codable, Equatable, Sendable {
  public let title: String
  public let subtitle: String
  public let symbol: String

  public init(title: String, subtitle: String, symbol: String) {
    self.title = title
    self.subtitle = subtitle
    self.symbol = symbol
  }
}

public struct BridgeDesktopChoice: Codable, Equatable, Sendable {
  public let id: String
  public let title: String
  public let detail: String?
  public let enabled: Bool

  public init(id: String, title: String, detail: String? = nil, enabled: Bool = true) {
    self.id = id
    self.title = title
    self.detail = detail
    self.enabled = enabled
  }
}
