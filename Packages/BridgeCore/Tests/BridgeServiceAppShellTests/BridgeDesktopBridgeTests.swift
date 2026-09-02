import BridgeDesktopUI
import BridgeIPC
import BridgeMCP
import Foundation
import XCTest

@testable import BridgeServiceAppShell

@MainActor
final class BridgeDesktopBridgeTests: XCTestCase {
  func testStateBuilderPublishesEveryPageFromLiveModel() async throws {
    let model = BridgeServiceAppModel(
      registration: BridgeDesktopTestServiceRegistration(status: .enabled),
      clientFactory: { TestBridgeServiceClient() },
      pollInterval: nil,
      connectionRetryDelay: .milliseconds(1),
      maximumConnectionAttempts: 1
    )
    await model.startAsync()

    let state = BridgeDesktopUIStateBuilder.build(from: model)
    XCTAssertNotNil(state.overview)
    XCTAssertNotNil(state.workbench)
    XCTAssertNotNil(state.projects)
    XCTAssertNotNil(state.logs)
    XCTAssertNotNil(state.connections)
    XCTAssertNotNil(state.settings)
    XCTAssertEqual(
      state.projects?.rows.map { $0.projectID } ?? [],
      model.projects.map { $0.projectID }
    )
    XCTAssertEqual(
      state.workbench?.tasks.map { $0.taskID } ?? [],
      model.tasks.map { $0.taskID }
    )
    XCTAssertEqual(
      state.connections?.providers.map { $0.providerID } ?? [],
      model.agentProviders.map { $0.providerID }
    )
  }

  func testLogCategoryUsesPersistedServiceEventKind() {
    XCTAssertEqual(
      BridgeDesktopLogPresentation.category(for: "execution.command_completed"),
      "command"
    )
    XCTAssertEqual(
      BridgeDesktopLogPresentation.category(for: "execution.file_changed"),
      "file"
    )
    XCTAssertEqual(
      BridgeDesktopLogPresentation.category(for: "task.failed"),
      "other"
    )
  }

  func testBrowserViewportCommandAcceptsFiniteLocalGeometryOnly() {
    let defaults = UserDefaults(suiteName: "BridgeDesktopBridgeTests.viewport")!
    defaults.set(true, forKey: "chatBrowserEnabled")
    let model = BridgeServiceAppModel(
      registration: BridgeDesktopTestServiceRegistration(status: .enabled),
      clientFactory: { TestBridgeServiceClient() },
      pollInterval: nil,
      userDefaults: defaults
    )
    model.selection = BridgeServiceNavigation.workbench
    let viewport = BridgeDesktopBrowserViewport(
      x: 10,
      y: 20,
      width: 300,
      height: 400,
      visible: true
    )
    BridgeDesktopCommandRouter.handle(
      BridgeDesktopCommandEnvelope(
        requestID: "viewport",
        command: .updateBrowserViewport,
        payload: BridgeDesktopCommandPayload(viewport: viewport)
      ),
      model: model
    )
    XCTAssertEqual(model.chatBrowserViewport, viewport)

    let invalid = BridgeDesktopBrowserViewport(
      x: -.infinity,
      y: 0,
      width: 300,
      height: 400,
      visible: true
    )
    BridgeDesktopCommandRouter.handle(
      BridgeDesktopCommandEnvelope(
        requestID: "invalid",
        command: .updateBrowserViewport,
        payload: BridgeDesktopCommandPayload(viewport: invalid)
      ),
      model: model
    )
    XCTAssertNil(model.chatBrowserViewport)
    defaults.removePersistentDomain(forName: "BridgeDesktopBridgeTests.viewport")
  }
}

@MainActor
private final class BridgeDesktopTestServiceRegistration: BridgeServiceRegistrationManaging {
  var status: BridgeServiceRegistrationStatus

  init(status: BridgeServiceRegistrationStatus) {
    self.status = status
  }

  func register() throws {
    status = .enabled
  }

  func unregister() async throws {
    status = .notRegistered
  }

  func openSystemSettings() {}
}
