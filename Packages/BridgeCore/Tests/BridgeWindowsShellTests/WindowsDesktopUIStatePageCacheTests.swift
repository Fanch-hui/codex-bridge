#if os(Windows)
  import BridgeDesktopUI
  import XCTest
  @testable import BridgeWindowsShell

  final class WindowsDesktopUIStatePageCacheTests: XCTestCase {
    func testCacheRetainsAnEmptyPageResult() {
      let cache = WindowsDesktopUIStatePageCache()
      let key = WindowsDesktopLogsCacheKey(nil)
      var buildCount = 0

      XCTAssertNil(
        cache.logs(key: key) {
          buildCount += 1
          return nil
        }
      )
      XCTAssertNil(
        cache.logs(key: key) {
          buildCount += 1
          return nil
        }
      )
      XCTAssertEqual(buildCount, 1)
    }

    func testPageCachesHaveIndependentEntries() {
      let cache = WindowsDesktopUIStatePageCache()
      var logBuilds = 0
      var settingsBuilds = 0
      let logsKey = WindowsDesktopLogsCacheKey(nil)
      let settingsKey = WindowsDesktopSettingsCacheKey(settings: nil, agentDefaults: nil)

      _ = cache.logs(key: logsKey) {
        logBuilds += 1
        return nil
      }
      _ = cache.settings(key: settingsKey) {
        settingsBuilds += 1
        return nil
      }
      _ = cache.logs(key: logsKey) {
        logBuilds += 1
        return nil
      }
      _ = cache.settings(key: settingsKey) {
        settingsBuilds += 1
        return nil
      }

      XCTAssertEqual(logBuilds, 1)
      XCTAssertEqual(settingsBuilds, 1)
    }

    func testConversationChangesOnlyInvalidateWorkbenchInput() {
      let management = makeManagement()
      let connections = makeConnections(tunnel: nil)
      var workbench = makeWorkbench()
      let baseProjects = WindowsDesktopProjectsCacheKey(
        workbench: workbench,
        management: management,
        workspace: nil
      )
      let baseConnections = WindowsDesktopConnectionsCacheKey(
        workbench: workbench,
        management: management,
        connections: connections,
        settings: nil
      )
      let baseWorkbench = WindowsDesktopWorkbenchCacheKey(
        workbench: workbench,
        management: management,
        browserAvailable: true,
        browserURL: nil,
        browserStatus: nil,
        browserCanGoBack: false,
        browserCanGoForward: false,
        modelRefreshInProgress: false,
        canRefreshModels: true
      )

      workbench.history = BridgeDesktopThreadHistoryState(
        conversation: [
          BridgeDesktopConversationEntry(
            id: "entry-1",
            role: "assistant",
            text: "流式消息已更新",
            isFinal: false
          )
        ]
      )

      XCTAssertEqual(
        baseProjects,
        WindowsDesktopProjectsCacheKey(
          workbench: workbench,
          management: management,
          workspace: nil
        )
      )
      XCTAssertEqual(
        baseConnections,
        WindowsDesktopConnectionsCacheKey(
          workbench: workbench,
          management: management,
          connections: connections,
          settings: nil
        )
      )
      XCTAssertNotEqual(
        baseWorkbench,
        WindowsDesktopWorkbenchCacheKey(
          workbench: workbench,
          management: management,
          browserAvailable: true,
          browserURL: nil,
          browserStatus: nil,
          browserCanGoBack: false,
          browserCanGoForward: false,
          modelRefreshInProgress: false,
          canRefreshModels: true
        )
      )
    }
  }
#endif
