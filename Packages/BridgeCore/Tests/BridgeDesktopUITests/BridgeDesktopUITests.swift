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
    let index = try BridgeDesktopUIResources.read(.indexHTML)
    XCTAssertTrue(index.contains("chat-browser-slot"))
    XCTAssertFalse(index.contains("placeholder-page"))
    let script = try BridgeDesktopUIResources.read(.appJS)
    XCTAssertTrue(script.contains(#"emit("ready")"#))
    XCTAssertTrue(script.contains("window.chrome.webview.addEventListener"))
    XCTAssertFalse(script.contains("https://"))
    XCTAssertTrue(try BridgeDesktopUIResources.read(.pagesJS).contains("updateBrowserViewport"))
    XCTAssertTrue(try BridgeDesktopUIResources.read(.pagesWorkbenchJS).contains("resolveApproval"))
    XCTAssertTrue(
      try BridgeDesktopUIResources.read(.pagesProjectsJS).contains("saveProjectBlacklist"))
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
      overview: overview,
      workbench: BridgeDesktopWorkbenchState(
        header: BridgeDesktopPageHeader(
          title: "工作台",
          subtitle: "任务",
          symbol: "bubble.left.and.text.bubble.right.fill"
        ),
        browser: BridgeDesktopBrowserSlot(visible: true, enabled: true)
      )
    )
    let data = try JSONEncoder().encode(state)
    XCTAssertEqual(try JSONDecoder().decode(BridgeDesktopUIState.self, from: data), state)
  }

  func testCommandEnvelopeDecodes() throws {
    let data = Data(
      #"{"version":1,"requestID":"request-7","command":"updateBrowserViewport","payload":{"viewport":{"x":1,"y":2,"width":640,"height":480,"visible":true}}}"#
        .utf8
    )
    let envelope = try JSONDecoder().decode(BridgeDesktopCommandEnvelope.self, from: data)
    XCTAssertEqual(envelope.version, BridgeDesktopCommandEnvelope.currentVersion)
    XCTAssertEqual(envelope.requestID, "request-7")
    XCTAssertEqual(envelope.command, .updateBrowserViewport)
    XCTAssertEqual(envelope.payload.viewport?.width, 640)
    XCTAssertTrue(envelope.payload.viewport?.visible == true)
  }
}
