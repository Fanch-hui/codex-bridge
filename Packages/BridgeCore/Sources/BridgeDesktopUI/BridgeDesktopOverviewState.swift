import Foundation

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
  public let command: BridgeDesktopCommand?

  public init(
    id: String,
    title: String,
    message: String,
    symbol: String,
    tone: BridgeDesktopStatusTone,
    destination: BridgeDesktopNavigation? = nil,
    command: BridgeDesktopCommand? = nil
  ) {
    self.id = id
    self.title = title
    self.message = message
    self.symbol = symbol
    self.tone = tone
    self.destination = destination
    self.command = command
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
