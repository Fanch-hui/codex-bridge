#if os(Windows)
  import BridgeDesktopUI
  import Foundation

  final class WindowsDesktopUIStatePageCache: @unchecked Sendable {
    private struct Entry<Key: Equatable, Value> {
      var key: Key?
      var value: Value?
      var hasValue = false
    }

    private let lock = NSLock()
    private var navigation = Entry<
      WindowsDesktopNavigationCacheKey, [BridgeDesktopNavigationItem]
    >()
    private var overview = Entry<WindowsDesktopOverviewCacheKey, BridgeDesktopOverviewState>()
    private var workbench = Entry<WindowsDesktopWorkbenchCacheKey, BridgeDesktopWorkbenchState>()
    private var projects = Entry<WindowsDesktopProjectsCacheKey, BridgeDesktopProjectsState>()
    private var logs = Entry<WindowsDesktopLogsCacheKey, BridgeDesktopLogsState?>()
    private var connections = Entry<
      WindowsDesktopConnectionsCacheKey, BridgeDesktopConnectionsState?
    >()
    private var settings = Entry<WindowsDesktopSettingsCacheKey, BridgeDesktopSettingsState?>()

    func navigation(
      key: WindowsDesktopNavigationCacheKey,
      build: () -> [BridgeDesktopNavigationItem]
    ) -> [BridgeDesktopNavigationItem] {
      lock.withLock { cached(key: key, entry: &navigation, build: build) }
    }

    func overview(
      key: WindowsDesktopOverviewCacheKey,
      build: () -> BridgeDesktopOverviewState
    ) -> BridgeDesktopOverviewState {
      lock.withLock { cached(key: key, entry: &overview, build: build) }
    }

    func workbench(
      key: WindowsDesktopWorkbenchCacheKey,
      build: () -> BridgeDesktopWorkbenchState
    ) -> BridgeDesktopWorkbenchState {
      lock.withLock { cached(key: key, entry: &workbench, build: build) }
    }

    func projects(
      key: WindowsDesktopProjectsCacheKey,
      build: () -> BridgeDesktopProjectsState
    ) -> BridgeDesktopProjectsState {
      lock.withLock { cached(key: key, entry: &projects, build: build) }
    }

    func logs(
      key: WindowsDesktopLogsCacheKey,
      build: () -> BridgeDesktopLogsState?
    ) -> BridgeDesktopLogsState? {
      lock.withLock { cached(key: key, entry: &logs, build: build) }
    }

    func connections(
      key: WindowsDesktopConnectionsCacheKey,
      build: () -> BridgeDesktopConnectionsState?
    ) -> BridgeDesktopConnectionsState? {
      lock.withLock { cached(key: key, entry: &connections, build: build) }
    }

    func settings(
      key: WindowsDesktopSettingsCacheKey,
      build: () -> BridgeDesktopSettingsState?
    ) -> BridgeDesktopSettingsState? {
      lock.withLock { cached(key: key, entry: &settings, build: build) }
    }

    private func cached<Key: Equatable, Value>(
      key: Key,
      entry: inout Entry<Key, Value>,
      build: () -> Value
    ) -> Value {
      if entry.hasValue, entry.key == key, let value = entry.value {
        return value
      }
      let value = build()
      entry.key = key
      entry.value = value
      entry.hasValue = true
      return value
    }
  }
#endif
