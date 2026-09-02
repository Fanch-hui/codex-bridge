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

public struct BridgeDesktopMetric: Codable, Equatable, Sendable {
  public let id: String
  public let title: String
  public let value: String
  public let symbol: String
  public let subtitle: String
  public let tone: BridgeDesktopStatusTone
  public let destination: BridgeDesktopNavigation?

  public init(
    id: String,
    title: String,
    value: String,
    symbol: String,
    subtitle: String,
    tone: BridgeDesktopStatusTone,
    destination: BridgeDesktopNavigation? = nil
  ) {
    self.id = id
    self.title = title
    self.value = value
    self.symbol = symbol
    self.subtitle = subtitle
    self.tone = tone
    self.destination = destination
  }
}

public struct BridgeDesktopServiceRow: Codable, Equatable, Sendable {
  public let id: String
  public let title: String
  public let value: String
  public let symbol: String
  public let tone: BridgeDesktopStatusTone
  public let destination: BridgeDesktopNavigation?

  public init(
    id: String,
    title: String,
    value: String,
    symbol: String,
    tone: BridgeDesktopStatusTone,
    destination: BridgeDesktopNavigation? = nil
  ) {
    self.id = id
    self.title = title
    self.value = value
    self.symbol = symbol
    self.tone = tone
    self.destination = destination
  }
}

public struct BridgeDesktopNotice: Codable, Equatable, Sendable {
  public let id: String
  public let title: String
  public let message: String
  public let symbol: String
  public let tone: BridgeDesktopStatusTone
  public let destination: BridgeDesktopNavigation?

  public init(
    id: String,
    title: String,
    message: String,
    symbol: String,
    tone: BridgeDesktopStatusTone,
    destination: BridgeDesktopNavigation? = nil
  ) {
    self.id = id
    self.title = title
    self.message = message
    self.symbol = symbol
    self.tone = tone
    self.destination = destination
  }
}

public struct BridgeDesktopRecentTask: Codable, Equatable, Sendable {
  public let id: String
  public let title: String
  public let projectName: String
  public let source: String
  public let status: String
  public let updatedAt: String

  public init(
    id: String,
    title: String,
    projectName: String,
    source: String,
    status: String,
    updatedAt: String
  ) {
    self.id = id
    self.title = title
    self.projectName = projectName
    self.source = source
    self.status = status
    self.updatedAt = updatedAt
  }
}

public struct BridgeDesktopActionLink: Codable, Equatable, Sendable {
  public let id: String
  public let title: String
  public let command: BridgeDesktopCommand
  public let destination: BridgeDesktopNavigation?
  public let taskID: String?

  public init(
    id: String,
    title: String,
    command: BridgeDesktopCommand,
    destination: BridgeDesktopNavigation? = nil,
    taskID: String? = nil
  ) {
    self.id = id
    self.title = title
    self.command = command
    self.destination = destination
    self.taskID = taskID
  }
}

public struct BridgeDesktopOverviewState: Codable, Equatable, Sendable {
  public let title: String
  public let subtitle: String
  public let notices: [BridgeDesktopNotice]
  public let metrics: [BridgeDesktopMetric]
  public let services: [BridgeDesktopServiceRow]
  public let serviceActions: [BridgeDesktopActionLink]
  public let recentTasks: [BridgeDesktopRecentTask]
  public let lastUpdatedAt: String?

  public init(
    title: String,
    subtitle: String,
    notices: [BridgeDesktopNotice],
    metrics: [BridgeDesktopMetric],
    services: [BridgeDesktopServiceRow],
    serviceActions: [BridgeDesktopActionLink] = [],
    recentTasks: [BridgeDesktopRecentTask],
    lastUpdatedAt: String? = nil
  ) {
    self.title = title
    self.subtitle = subtitle
    self.notices = notices
    self.metrics = metrics
    self.services = services
    self.serviceActions = serviceActions
    self.recentTasks = recentTasks
    self.lastUpdatedAt = lastUpdatedAt
  }
}

public struct BridgeDesktopUIState: Codable, Equatable, Sendable {
  public let navigation: [BridgeDesktopNavigationItem]
  public let selectedNavigation: BridgeDesktopNavigation
  public let connectionLabel: String
  public let connectionTone: BridgeDesktopStatusTone
  public let isRefreshing: Bool
  public let overview: BridgeDesktopOverviewState?

  public init(
    navigation: [BridgeDesktopNavigationItem] = BridgeDesktopNavigation.canonicalItems,
    selectedNavigation: BridgeDesktopNavigation,
    connectionLabel: String,
    connectionTone: BridgeDesktopStatusTone,
    isRefreshing: Bool,
    overview: BridgeDesktopOverviewState?
  ) {
    self.navigation = navigation
    self.selectedNavigation = selectedNavigation
    self.connectionLabel = connectionLabel
    self.connectionTone = connectionTone
    self.isRefreshing = isRefreshing
    self.overview = overview
  }
}

public enum BridgeDesktopCommand: String, Codable, Sendable {
  case ready
  case refresh
  case selectPage
  case openWorkbench
  case openProjects
  case openConnections
  case openSettings
  case openLogs
  case openTask
}

public struct BridgeDesktopCommandPayload: Codable, Equatable, Sendable {
  public let navigation: BridgeDesktopNavigation?
  public let taskID: String?

  public init(
    navigation: BridgeDesktopNavigation? = nil,
    taskID: String? = nil
  ) {
    self.navigation = navigation
    self.taskID = taskID
  }
}

public struct BridgeDesktopCommandEnvelope: Codable, Equatable, Sendable {
  public static let currentVersion = 1

  public let version: Int
  public let requestID: String
  public let command: BridgeDesktopCommand
  public let payload: BridgeDesktopCommandPayload

  public init(
    requestID: String,
    command: BridgeDesktopCommand,
    payload: BridgeDesktopCommandPayload = .init()
  ) {
    self.version = Self.currentVersion
    self.requestID = requestID
    self.command = command
    self.payload = payload
  }
}
