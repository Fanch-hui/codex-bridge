import AppKit
import Foundation

public enum BridgeDesktopWindowNotifications {
  public static let openPreferences = Notification.Name("BridgeDesktop.openPreferences")
  public static let openMain = Notification.Name("BridgeDesktop.openMain")
}

enum BridgeDesktopSurface: Equatable {
  case main
  case preferences
}

struct BridgeDesktopWindowDestination {
  enum Kind: Equatable {
    case dshSettings
    case connectionDetail
    case settingsDetail
    case workbenchSession
  }

  let id = UUID()
  let kind: Kind
  let value: String

  var script: String? {
    guard let data = try? JSONEncoder().encode(value),
      let argument = String(data: data, encoding: .utf8)
    else { return nil }
    switch kind {
    case .dshSettings:
      return "Boolean(window.CodexBridgeDesktopDSHWorkbench?.openSettings(\(argument)))"
    case .connectionDetail:
      return "Boolean(window.CodexBridgeDesktopConnectionsPage?.openDetail(\(argument)))"
    case .settingsDetail:
      return "Boolean(window.CodexBridgeDesktopSettingsPage?.openDetail(\(argument)))"
    case .workbenchSession:
      return
        "window.dispatchEvent(new CustomEvent('codex-bridge-open-workbench-session',{detail:{sessionID:\(argument)}}))"
    }
  }
}

@MainActor
final class BridgeDesktopWindowCoordinator {
  static let shared = BridgeDesktopWindowCoordinator()

  private weak var main: BridgeDesktopWebView.Coordinator?
  private weak var preferences: BridgeDesktopWebView.Coordinator?
  private var mainDestination: BridgeDesktopWindowDestination?
  private var preferencesDestination: BridgeDesktopWindowDestination?

  func attach(_ coordinator: BridgeDesktopWebView.Coordinator, surface: BridgeDesktopSurface) {
    switch surface {
    case .main: main = coordinator
    case .preferences: preferences = coordinator
    }
  }

  func showMainWindow() -> Bool {
    NSApp.activate(ignoringOtherApps: true)
    guard let window = main?.webView?.window else { return false }
    window.makeKeyAndOrderFront(nil)
    return true
  }

  func openMain(destination: BridgeDesktopWindowDestination? = nil) {
    mainDestination = destination
    if showMainWindow() {
      main?.sendPendingDestination()
    } else {
      NotificationCenter.default.post(name: BridgeDesktopWindowNotifications.openMain, object: nil)
    }
  }

  func openPreferences(destination: BridgeDesktopWindowDestination? = nil) {
    preferencesDestination = destination
    NotificationCenter.default.post(
      name: BridgeDesktopWindowNotifications.openPreferences, object: nil)
    preferences?.sendPendingDestination()
  }

  func pendingDestination(for surface: BridgeDesktopSurface) -> BridgeDesktopWindowDestination? {
    switch surface {
    case .main: mainDestination
    case .preferences: preferencesDestination
    }
  }

  func completeDestination(_ id: UUID, surface: BridgeDesktopSurface) {
    switch surface {
    case .main:
      if mainDestination?.id == id { mainDestination = nil }
    case .preferences:
      if preferencesDestination?.id == id { preferencesDestination = nil }
    }
  }
}
