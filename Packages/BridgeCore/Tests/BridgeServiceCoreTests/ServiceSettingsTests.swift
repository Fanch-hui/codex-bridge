import BridgeServiceCore
import XCTest

final class ServiceSettingsTests: XCTestCase {
  func testMCPToolsDefaultToFull() async throws {
    let fixture = try ServiceCoreFixture()
    defer { fixture.remove() }
    let settings = ServiceSettings(store: try SimpleServiceStore(path: fixture.databasePath))
    let mode = try await settings.exposureMode()
    XCTAssertEqual(mode, .full)
    let qwenMode = try await settings.qwenStudioExposureMode()
    XCTAssertEqual(qwenMode, .full)
  }

  func testWorkbenchPermissionModeDefaultsToWorkspaceWriteAndPersistsReadOnly()
    async throws
  {
    let fixture = try ServiceCoreFixture()
    defer { fixture.remove() }
    let settings = ServiceSettings(store: try SimpleServiceStore(path: fixture.databasePath))

    let initialMode = try await settings.workbenchPermissionMode()
    XCTAssertEqual(initialMode, .workspaceWrite)

    try await settings.setWorkbenchPermissionMode(.readOnly)

    let reopened = ServiceSettings(
      store: try SimpleServiceStore(path: fixture.databasePath)
    )
    let persistedMode = try await reopened.workbenchPermissionMode()
    XCTAssertEqual(persistedMode, .readOnly)
  }

  func testTaskStartApprovalRequiresLocalApprovalByDefaultAndPersistsAutoMode() async throws {
    let fixture = try ServiceCoreFixture()
    defer { fixture.remove() }
    let settings = ServiceSettings(store: try SimpleServiceStore(path: fixture.databasePath))

    let defaultMode = try await settings.taskStartApprovalMode()
    XCTAssertEqual(defaultMode, .require)

    try await settings.setTaskStartApprovalMode(.auto)

    let persistedMode = try await settings.taskStartApprovalMode()
    XCTAssertEqual(persistedMode, .auto)
  }

  func testAntigravityDefaultsToWorkspaceWriteAndPersistsModelAndPermission() async throws {
    let fixture = try ServiceCoreFixture()
    defer { fixture.remove() }
    let settings = ServiceSettings(store: try SimpleServiceStore(path: fixture.databasePath))

    let initialModel = try await settings.antigravityDefaultModel()
    let initialPermissionMode = try await settings.antigravityDefaultPermissionMode()
    XCTAssertNil(initialModel)
    XCTAssertEqual(initialPermissionMode, "workspace-write")

    try await settings.setAntigravityDefaultModel("antigravity/model")
    try await settings.setAntigravityDefaultPermissionMode("read-only")

    let persistedModel = try await settings.antigravityDefaultModel()
    let persistedPermissionMode = try await settings.antigravityDefaultPermissionMode()
    XCTAssertEqual(persistedModel, "antigravity/model")
    XCTAssertEqual(persistedPermissionMode, "read-only")
  }

  func testAntigravityPermissionModeRejectsUnsupportedValue() async throws {
    let fixture = try ServiceCoreFixture()
    defer { fixture.remove() }
    let settings = ServiceSettings(store: try SimpleServiceStore(path: fixture.databasePath))

    do {
      try await settings.setAntigravityDefaultPermissionMode("danger-full-access")
      XCTFail("Expected unsupported Antigravity permission mode to fail.")
    } catch ServiceStoreError.invalidArgument {}
  }

  func testDeepSeekPermissionModeDefaultsToWorkspaceWriteAndPersistsReadOnly() async throws {
    let fixture = try ServiceCoreFixture()
    defer { fixture.remove() }
    let settings = ServiceSettings(store: try SimpleServiceStore(path: fixture.databasePath))

    let defaultMode = try await settings.deepSeekHarnessDefaultPermissionMode()
    XCTAssertEqual(defaultMode, "workspace-write")

    try await settings.setDeepSeekHarnessDefaultPermissionMode("read-only")

    let persistedMode = try await settings.deepSeekHarnessDefaultPermissionMode()
    XCTAssertEqual(persistedMode, "read-only")
  }

  func testDeepSeekPermissionModeRejectsUnsupportedValue() async throws {
    let fixture = try ServiceCoreFixture()
    defer { fixture.remove() }
    let settings = ServiceSettings(store: try SimpleServiceStore(path: fixture.databasePath))

    do {
      try await settings.setDeepSeekHarnessDefaultPermissionMode("danger-full-access")
      XCTFail("Expected unsupported DeepSeek permission mode to fail.")
    } catch ServiceStoreError.invalidArgument {}
  }
}
