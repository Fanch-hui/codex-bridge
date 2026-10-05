#if os(Windows) || os(Linux)
  import BridgeDesktopUI
  import Foundation

  struct WindowsProjectManagementDisplay: Equatable, Sendable {
    let rows: [String]
    let selectedIndex: Int?
    let detailText: String
    let registerEnabled: Bool
    let removeEnabled: Bool
    let statusText: String
    var projectItems: [BridgeDesktopProjectRow] = []
  }

  struct WindowsAgentManagementDisplay: Equatable, Sendable {
    let providerRows: [String]
    let providerIDs: [String]
    let selectedProviderIndex: Int?
    let providerDetailText: String
    let providerRequiresConfiguration: Bool
    let installationRows: [String]
    let selectedInstallationIndex: Int?
    let installationDetailText: String
    let registerEnabled: Bool
    let enableEnabled: Bool
    let disableEnabled: Bool
    let reprobeEnabled: Bool
    let acceptReplacementEnabled: Bool
    let removeEnabled: Bool
    let statusText: String
    var providerItems: [BridgeDesktopAgentProviderRow] = []
    var installationItems: [BridgeDesktopAgentInstallationRow] = []
    var isManagingAgents = false
    var agentOperationRevision = 0
    var setupOperations: [BridgeDesktopAgentSetupState] = []
  }

  struct WindowsManagementDisplay: Equatable, Sendable {
    let connectionState: WindowsWorkbenchDisplay.ConnectionState
    let availableAgentCount: Int
    let project: WindowsProjectManagementDisplay
    let agent: WindowsAgentManagementDisplay
  }

  final class ManagementDisplayBox: @unchecked Sendable {
    private let lock = NSLock()
    private var version: UInt64 = 0

    var revision: UInt64 {
      lock.lock()
      defer { lock.unlock() }
      return version
    }
    private var value: WindowsManagementDisplay

    init(value: WindowsManagementDisplay) {
      self.value = value
    }

    func current() -> WindowsManagementDisplay {
      lock.lock()
      defer { lock.unlock() }
      return value
    }

    func store(_ value: WindowsManagementDisplay) {
      lock.lock()
      defer { lock.unlock() }
      guard self.value != value else { return }
      self.value = value
      version &+= 1
    }
  }
#endif
