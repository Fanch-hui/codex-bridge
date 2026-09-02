#if os(Windows)
  import BridgeDesktopUI
  import BridgeIPC
  import BridgeMCP
  import BridgeServiceAppCore
  import Foundation

  struct WindowsWorkspaceDisplay: Equatable, Sendable {
    let connectionState: WindowsWorkbenchDisplay.ConnectionState
    let projectRows: [String]
    let selectedProjectIndex: Int?
    let commandRows: [String]
    let selectedCommandIndex: Int?
    let commandDetailText: String
    let commandName: String
    let commandExecutable: String
    let commandArguments: String
    let commandWorkingDirectory: String
    let commandRequiresNetwork: Bool
    let commandRisk: String
    let commandMode: String
    let commandModeValues: [String]
    let skillRows: [String]
    let selectedSkillIndex: Int?
    let skillDetailText: String
    let threadRows: [String]
    let selectedThreadIndex: Int?
    let threadDetailText: String
    let blacklistRows: [String]
    let selectedBlacklistIndex: Int?
    let blacklistExecutable: String
    let blacklistPattern: String
    let saveCommandEnabled: Bool
    let removeCommandEnabled: Bool
    let saveModeEnabled: Bool
    let saveBlacklistEnabled: Bool
    let removeBlacklistEnabled: Bool
    let statusText: String
    let selectedProjectID: String? = nil
    let selectedCommandID: String? = nil
    let selectedSkillID: String? = nil
    let selectedThreadID: String? = nil
    let fileWritePermission: String = "denied"
    let commands: [BridgeDesktopWorkspaceCommand] = []
    let blacklist: [BridgeDesktopBlacklistRule] = []
    let skills: [BridgeDesktopSkillRow] = []
    let threads: [BridgeDesktopThreadRow] = []
    let verificationCommands: [String] = []
    let threadCount: Int? = nil
  }

  struct WindowsAgentDefaultsDisplay: Equatable, Sendable {
    let connectionState: WindowsWorkbenchDisplay.ConnectionState
    let providerRows: [String]
    let selectedProviderIndex: Int?
    let installationRows: [String]
    let selectedInstallationIndex: Int?
    let installationDetailText: String
    let modelRows: [String]
    let modelIDs: [String]
    let selectedModelIndex: Int?
    let effortValues: [String]
    let selectedEffortIndex: Int?
    let permissionValues: [String]
    let selectedPermissionIndex: Int?
    let refreshModelsEnabled: Bool
    let saveEnabled: Bool
    let statusText: String
    let providerItems: [BridgeDesktopAgentProviderRow] = []
    let installationItems: [BridgeDesktopAgentInstallationRow] = []
    let selectedProviderID: String? = nil
    let selectedInstallationID: String? = nil
    let selectedModelID: String? = nil
    let selectedEffort: String = ""
    let selectedPermissionMode: String = ""
    let defaultErrorMessage: String? = nil
    let modelOptions: [BridgeDesktopModelOption] = []
  }

  struct WindowsLogDisplay: Equatable, Sendable {
    let connectionState: WindowsWorkbenchDisplay.ConnectionState
    let searchText: String
    let projectRows: [String]
    let selectedProjectIndex: Int
    let kindRows: [String]
    let selectedKindIndex: Int
    let rows: [String]
    let selectedIndex: Int?
    let detailText: String
    let refreshEnabled: Bool
    let copyEnabled: Bool
    let copyText: String
    let statusText: String
    let rowsTyped: [BridgeDesktopLogRow] = []
    let projectOptions: [BridgeDesktopChoice] = []
    let selectedProjectID: String? = nil
    let selectedKind: String = "all"
    let selectedRowID: String? = nil
  }

  struct WindowsSettingsDisplay: Equatable, Sendable {
    let connectionState: WindowsWorkbenchDisplay.ConnectionState
    let modelRows: [String]
    let modelIDs: [String]
    let selectedExecutionModelIndex: Int?
    let selectedSupervisorModelIndex: Int?
    let effortValues: [String]
    let selectedExecutionEffortIndex: Int?
    let selectedSupervisorEffortIndex: Int?
    let accessValues: [String]
    let selectedAccessIndex: Int?
    let supervisorEnabled: Bool
    let fastModeEnabled: Bool
    let directApprovalValues: [String]
    let selectedDirectApprovalIndex: Int?
    let taskStartApprovalValues: [String]
    let selectedTaskStartApprovalIndex: Int?
    let customInstructions: String
    let savePreferencesEnabled: Bool
    let saveInstructionsEnabled: Bool
    let saveDirectApprovalEnabled: Bool
    let saveTaskStartApprovalEnabled: Bool
    let statusText: String
    let supervisorAvailable: Bool = false
    let executionModel: String = ""
    let executionEffort: String = ""
    let supervisorModel: String = ""
    let supervisorEffort: String = ""
    let accessMode: String = "request-approval"
    let directApprovalMode: String = "require"
    let taskStartApprovalMode: String = "require"
    let modelOptions: [BridgeDesktopModelOption] = []
  }

  final class AuxiliaryDisplayBox<Value: Equatable & Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(value: Value) { self.value = value }

    func current() -> Value {
      lock.lock()
      defer { lock.unlock() }
      return value
    }

    func store(_ value: Value) {
      lock.lock()
      self.value = value
      lock.unlock()
    }
  }
#endif
