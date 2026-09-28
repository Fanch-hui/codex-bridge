#if os(Windows)
  import BridgeDesktopUI
  import Foundation

  /// Page vocabulary shared by the command bus and the rendered desktop surface.
  /// Titles and copy live in `BridgeDesktopNavigation`; the host holds no page text.
  enum WindowsMainPage: Int, CaseIterable, Sendable {
    case overview
    case workbench
    case projects
    case logs
    case connections
    case settings
  }

  enum MainWindowCommand: Equatable {
    case desktopCommand(BridgeDesktopCommandEnvelope)
    case selectPage(index: Int)
    case windowVisibilityChanged(Bool)
    case refreshAll
    case registerProject(name: String, path: String)
    case registerAgentFromDesktop(
      providerID: String,
      displayName: String,
      executablePath: String,
      configurationPath: String?,
      qoderDistribution: String?
    )
  }
#endif
