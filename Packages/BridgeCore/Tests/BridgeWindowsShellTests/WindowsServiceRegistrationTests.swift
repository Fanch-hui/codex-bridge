import BridgeDesktopUI
import XCTest

@testable import BridgeWindowsShell

final class WindowsServiceRegistrationTests: XCTestCase {
  override func setUp() {
    super.setUp()
    WindowsServiceRegistration.resetForTesting()
  }

  override func tearDown() {
    WindowsServiceRegistration.resetForTesting()
    #if os(Windows)
      WindowsServiceRegistration.restoreLiveBackendForTesting()
    #endif
    super.tearDown()
  }

  func testFormattedValueQuotesUnquotedPath() {
    let unquoted = #"C:\Program Files\CodexBridge\codex-bridge-service.exe"#
    let formatted = WindowsServiceRegistration.formattedValue(for: unquoted)
    XCTAssertEqual(
      formatted,
      #" "C:\Program Files\CodexBridge\codex-bridge-service.exe" "#.trimmingCharacters(
        in: .whitespaces))
    XCTAssertTrue(formatted.hasPrefix("\""))
    XCTAssertTrue(formatted.hasSuffix("\""))
  }

  func testFormattedValuePreservesAlreadyQuotedPath() {
    let alreadyQuoted = #""C:\Codex\service.exe""#
    let formatted = WindowsServiceRegistration.formattedValue(for: alreadyQuoted)
    XCTAssertEqual(formatted, #""C:\Codex\service.exe""#)
  }

  func testFormattedValueTrimsWhitespace() {
    let withSpaces = #"   C:\Path\service.exe   "#
    let formatted = WindowsServiceRegistration.formattedValue(for: withSpaces)
    XCTAssertEqual(formatted, #""C:\Path\service.exe""#)

    let quotedWithSpaces = #"   "C:\Path\service.exe"   "#
    let formattedQuoted = WindowsServiceRegistration.formattedValue(for: quotedWithSpaces)
    XCTAssertEqual(formattedQuoted, #""C:\Path\service.exe""#)
  }

  func testStartupCommandUsesGuiShell() {
    let applicationPath = #"C:\Program Files\CodexBridge\codex-bridge-windows-app.exe"#
    XCTAssertEqual(
      WindowsServiceRegistration.startupCommand(for: applicationPath),
      #""C:\Program Files\CodexBridge\codex-bridge-windows-app.exe" --ensure-service"#
    )
  }

  func testUnquotedPathAndNormalization() {
    let raw = #""C:\My Program\Service.EXE""#
    XCTAssertEqual(
      WindowsServiceRegistration.unquotedPath(from: raw),
      #"C:\My Program\Service.EXE"#
    )
    XCTAssertEqual(
      WindowsServiceRegistration.normalizePath(raw),
      #"c:\my program\service.exe"#
    )
  }

  func testRegistrationLifecycle() throws {
    XCTAssertFalse(WindowsServiceRegistration.isRegistered())

    let servicePath = #"C:\Codex\codex-bridge-service.exe"#
    try WindowsServiceRegistration.register(executablePath: servicePath)
    XCTAssertTrue(WindowsServiceRegistration.isRegistered())
    XCTAssertTrue(WindowsServiceRegistration.isRegistered(executablePath: servicePath))
    XCTAssertTrue(
      WindowsServiceRegistration.isRegistered(
        executablePath: #""c:\codex\codex-bridge-service.exe""#))
    XCTAssertFalse(
      WindowsServiceRegistration.isRegistered(executablePath: #"C:\Other\service.exe"#))

    try WindowsServiceRegistration.unregister()
    XCTAssertFalse(WindowsServiceRegistration.isRegistered())

    // Idempotent unregister
    XCTAssertNoThrow(try WindowsServiceRegistration.unregister())
  }

  func testRegisterEmptyPathThrows() {
    XCTAssertThrowsError(try WindowsServiceRegistration.register(executablePath: "")) { error in
      XCTAssertEqual(error as? WindowsServiceRegistrationError, .executableNotFound)
    }
  }

  #if os(Windows)
    func testCommandRouterRoutesServiceCommands() {
      let registerEnvelope = BridgeDesktopCommandEnvelope(
        requestID: "req-1",
        command: .registerService
      )
      XCTAssertEqual(
        WindowsDesktopUICommandRouter.command(for: registerEnvelope),
        .registerService
      )

      let unregisterEnvelope = BridgeDesktopCommandEnvelope(
        requestID: "req-2",
        command: .unregisterService
      )
      XCTAssertEqual(
        WindowsDesktopUICommandRouter.command(for: unregisterEnvelope),
        .unregisterService
      )

      let keepRunningEnvelope = BridgeDesktopCommandEnvelope(
        requestID: "req-3",
        command: .setKeepServiceRunning,
        payload: BridgeDesktopCommandPayload(keepServiceRunningAfterExit: true)
      )
      XCTAssertEqual(
        WindowsDesktopUICommandRouter.command(for: keepRunningEnvelope),
        .setKeepServiceRunning(true)
      )

      let stopRunningEnvelope = BridgeDesktopCommandEnvelope(
        requestID: "req-4",
        command: .setKeepServiceRunning,
        payload: BridgeDesktopCommandPayload(keepServiceRunningAfterExit: false)
      )
      XCTAssertEqual(
        WindowsDesktopUICommandRouter.command(for: stopRunningEnvelope),
        .setKeepServiceRunning(false)
      )
    }

    func testStateBuilderReflectsServiceRegistration() {
      let settingsRegistered = makeSettings(
        keepServiceRunningAfterExit: true,
        serviceRegistered: true
      )
      let state = WindowsDesktopUIStateBuilder.build(
        workbench: makeWorkbench(),
        management: makeManagement(),
        settings: settingsRegistered,
        selectedNavigation: .settings
      )

      XCTAssertEqual(state.settings?.serviceRegistered, true)
      XCTAssertEqual(state.settings?.canChangeService, true)
      XCTAssertEqual(state.settings?.keepServiceRunningAfterExit, true)
      XCTAssertEqual(state.settings?.servicePlatform, "Windows")
      XCTAssertEqual(
        state.settings?.serviceDescription,
        "Windows 用户登录自动启动后台 Service，退出窗口后继续运行。"
      )

      let settingsUnregistered = makeSettings(
        keepServiceRunningAfterExit: false,
        serviceRegistered: false
      )
      let state2 = WindowsDesktopUIStateBuilder.build(
        workbench: makeWorkbench(),
        management: makeManagement(),
        settings: settingsUnregistered,
        selectedNavigation: .settings
      )

      XCTAssertEqual(state2.settings?.serviceRegistered, false)
      XCTAssertEqual(state2.settings?.canChangeService, true)
      XCTAssertEqual(state2.settings?.keepServiceRunningAfterExit, false)
    }
  #endif
}
