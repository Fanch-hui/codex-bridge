import BridgeDesktopUI
import XCTest

final class BridgeDesktopUITests: XCTestCase {
  func testResourcesArePackagedAndReadable() throws {
    XCTAssertNotNil(BridgeDesktopUI.indexURL())
    for resource in BridgeDesktopUIResource.allCases {
      XCTAssertNotNil(BridgeDesktopUIResources.url(for: resource))
      XCTAssertFalse(try BridgeDesktopUIResources.read(resource).isEmpty)
    }

    XCTAssertTrue(try BridgeDesktopUIResources.read(.indexHTML).contains("Codex Bridge"))
    let script = try BridgeDesktopUIResources.read(.appJS)
    XCTAssertTrue(script.contains(#"emit("ready")"#))
    XCTAssertTrue(script.contains("window.chrome.webview.addEventListener"))
    XCTAssertFalse(script.contains("https://"))
  }

  func testStateRoundTripsThroughJSON() throws {
    let overview = BridgeDesktopOverviewState(
      title: "概览",
      subtitle: "状态",
      notices: [],
      metrics: [
        BridgeDesktopMetric(
          id: "running",
          title: "运行中任务",
          value: "2",
          symbol: "bolt.fill",
          subtitle: "当前执行",
          tone: .running,
          destination: .workbench
        )
      ],
      services: [],
      serviceActions: [
        BridgeDesktopActionLink(
          id: "connections",
          title: "管理连接与 Agent →",
          command: .openConnections
        )
      ],
      recentTasks: [],
      lastUpdatedAt: "2026-09-01T23:46:31Z"
    )
    let state = BridgeDesktopUIState(
      selectedNavigation: .overview,
      connectionLabel: "已连接",
      connectionTone: .success,
      isRefreshing: false,
      overview: overview
    )
    let data = try JSONEncoder().encode(state)
    XCTAssertEqual(try JSONDecoder().decode(BridgeDesktopUIState.self, from: data), state)
  }

  func testCommandEnvelopeDecodes() throws {
    let data = Data(
      #"{"version":1,"requestID":"request-7","command":"selectPage","payload":{"navigation":"projects","taskID":null}}"#
        .utf8
    )
    let envelope = try JSONDecoder().decode(BridgeDesktopCommandEnvelope.self, from: data)
    XCTAssertEqual(envelope.version, BridgeDesktopCommandEnvelope.currentVersion)
    XCTAssertEqual(envelope.requestID, "request-7")
    XCTAssertEqual(envelope.command, .selectPage)
    XCTAssertEqual(envelope.payload.navigation, .projects)
    XCTAssertNil(envelope.payload.taskID)
  }
}
