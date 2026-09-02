import Foundation

public struct BridgeDesktopProjectRow: Codable, Equatable, Sendable {
  public let projectID: String
  public let name: String
  public let detail: String?
  public let gitState: String?
  public let readPermission: String
  public let writePermission: String
  public let networkPermission: String
  public let selected: Bool

  public init(
    projectID: String,
    name: String,
    detail: String? = nil,
    gitState: String? = nil,
    readPermission: String,
    writePermission: String,
    networkPermission: String,
    selected: Bool = false
  ) {
    self.projectID = projectID
    self.name = name
    self.detail = detail
    self.gitState = gitState
    self.readPermission = readPermission
    self.writePermission = writePermission
    self.networkPermission = networkPermission
    self.selected = selected
  }
}

public struct BridgeDesktopWorkspaceCommand: Codable, Equatable, Sendable {
  public let commandID: String
  public let name: String
  public let executable: String
  public let arguments: [String]
  public let workingDirectory: String?
  public let requiresNetwork: Bool
  public let risk: String

  public init(
    commandID: String,
    name: String,
    executable: String,
    arguments: [String] = [],
    workingDirectory: String? = nil,
    requiresNetwork: Bool = false,
    risk: String = "normal"
  ) {
    self.commandID = commandID
    self.name = name
    self.executable = executable
    self.arguments = arguments
    self.workingDirectory = workingDirectory
    self.requiresNetwork = requiresNetwork
    self.risk = risk
  }
}

public struct BridgeDesktopBlacklistRule: Codable, Equatable, Sendable {
  public let ruleID: String
  public let executable: String?
  public let pattern: String?

  public init(ruleID: String, executable: String? = nil, pattern: String? = nil) {
    self.ruleID = ruleID
    self.executable = executable
    self.pattern = pattern
  }
}

public struct BridgeDesktopWorkspaceState: Codable, Equatable, Sendable {
  public let fileWritePermission: String
  public let commandMode: String
  public let commandModeOptions: [BridgeDesktopChoice]
  public let commands: [BridgeDesktopWorkspaceCommand]
  public let blacklist: [BridgeDesktopBlacklistRule]
  public let canSaveMode: Bool
  public let canSaveCommand: Bool
  public let canRemoveCommand: Bool
  public let canSaveBlacklist: Bool
  public let canRemoveBlacklist: Bool

  public init(
    fileWritePermission: String,
    commandMode: String,
    commandModeOptions: [BridgeDesktopChoice] = [],
    commands: [BridgeDesktopWorkspaceCommand] = [],
    blacklist: [BridgeDesktopBlacklistRule] = [],
    canSaveMode: Bool = true,
    canSaveCommand: Bool = true,
    canRemoveCommand: Bool = true,
    canSaveBlacklist: Bool = true,
    canRemoveBlacklist: Bool = true
  ) {
    self.fileWritePermission = fileWritePermission
    self.commandMode = commandMode
    self.commandModeOptions = commandModeOptions
    self.commands = commands
    self.blacklist = blacklist
    self.canSaveMode = canSaveMode
    self.canSaveCommand = canSaveCommand
    self.canRemoveCommand = canRemoveCommand
    self.canSaveBlacklist = canSaveBlacklist
    self.canRemoveBlacklist = canRemoveBlacklist
  }
}

public struct BridgeDesktopThreadRow: Codable, Equatable, Sendable {
  public let threadID: String
  public let title: String
  public let status: String
  public let updatedAt: String?
  public let preview: String?

  public init(
    threadID: String,
    title: String,
    status: String,
    updatedAt: String? = nil,
    preview: String? = nil
  ) {
    self.threadID = threadID
    self.title = title
    self.status = status
    self.updatedAt = updatedAt
    self.preview = preview
  }
}

public struct BridgeDesktopSkillRow: Codable, Equatable, Sendable {
  public let skillID: String
  public let name: String
  public let scope: String?
  public let description: String?
  public let actionCount: Int
  public let enabled: Bool

  public init(
    skillID: String,
    name: String,
    scope: String? = nil,
    description: String? = nil,
    actionCount: Int = 0,
    enabled: Bool = true
  ) {
    self.skillID = skillID
    self.name = name
    self.scope = scope
    self.description = description
    self.actionCount = actionCount
    self.enabled = enabled
  }
}

public struct BridgeDesktopProjectsState: Codable, Equatable, Sendable {
  public let header: BridgeDesktopPageHeader
  public let rows: [BridgeDesktopProjectRow]
  public let selectedProjectID: String?
  public let selectedProjectDetail: String?
  public let policyOptions: [BridgeDesktopChoice]
  public let readOptions: [BridgeDesktopChoice]
  public let writeOptions: [BridgeDesktopChoice]
  public let networkOptions: [BridgeDesktopChoice]
  public let workspace: BridgeDesktopWorkspaceState?
  public let verificationCommands: [String]
  public let threadCount: Int?
  public let threads: [BridgeDesktopThreadRow]
  public let skills: [BridgeDesktopSkillRow]
  public let canRegister: Bool
  public let canRemove: Bool
  public let canSavePolicy: Bool

  public init(
    header: BridgeDesktopPageHeader,
    rows: [BridgeDesktopProjectRow] = [],
    selectedProjectID: String? = nil,
    selectedProjectDetail: String? = nil,
    policyOptions: [BridgeDesktopChoice] = [],
    readOptions: [BridgeDesktopChoice] = [],
    writeOptions: [BridgeDesktopChoice] = [],
    networkOptions: [BridgeDesktopChoice] = [],
    workspace: BridgeDesktopWorkspaceState? = nil,
    verificationCommands: [String] = [],
    threadCount: Int? = nil,
    threads: [BridgeDesktopThreadRow] = [],
    skills: [BridgeDesktopSkillRow] = [],
    canRegister: Bool = true,
    canRemove: Bool = false,
    canSavePolicy: Bool = false
  ) {
    self.header = header
    self.rows = rows
    self.selectedProjectID = selectedProjectID
    self.selectedProjectDetail = selectedProjectDetail
    self.policyOptions = policyOptions
    self.readOptions = readOptions
    self.writeOptions = writeOptions
    self.networkOptions = networkOptions
    self.workspace = workspace
    self.verificationCommands = verificationCommands
    self.threadCount = threadCount
    self.threads = threads
    self.skills = skills
    self.canRegister = canRegister
    self.canRemove = canRemove
    self.canSavePolicy = canSavePolicy
  }
}
