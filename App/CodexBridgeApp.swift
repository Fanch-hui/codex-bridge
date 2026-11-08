import AppKit
import BridgeLocalMCP
import BridgeServiceAppShell
import SwiftUI

@main
struct CodexBridgeApp: App {
  private static let mainWindowID = "main"
  @NSApplicationDelegateAdaptor(CodexBridgeAppDelegate.self) private var appDelegate
  @StateObject private var model: BridgeServiceAppModel

  init() {
    MCPStdioEntryPoint.runIfRequested()
    MacAppUpdateHelper.runIfRequested()
    MacConnectorUpdateEntryPoint.runIfRequested()
    let model = BridgeServiceAppModel()
    _model = StateObject(wrappedValue: model)
    appDelegate.install(model)
  }

  var body: some Scene {
    WindowGroup("Codex Bridge", id: Self.mainWindowID) {
      BridgeServiceRootView(model: model)
        .frame(minWidth: 720, minHeight: 520)
        .modifier(PreferencesWindowOpenHandler())
    }
    .defaultSize(width: 1180, height: 760)
    .windowStyle(.hiddenTitleBar)
    .commands {
      BridgeServiceCommands(model: model, mainWindowID: Self.mainWindowID)
    }

    Settings {
      BridgeServicePreferencesView(model: model, mainWindowID: Self.mainWindowID)
    }

    MenuBarExtra {
      BridgeServiceMenuBarView(model: model, mainWindowID: Self.mainWindowID)
    } label: {
      Label("Codex Bridge", systemImage: "link")
        .accessibilityLabel("Codex Bridge")
    }
  }
}

private struct PreferencesWindowOpenHandler: ViewModifier {
  @Environment(\.openSettings) private var openSettings

  func body(content: Content) -> some View {
    content.onReceive(
      NotificationCenter.default.publisher(for: BridgeDesktopWindowNotifications.openPreferences)
    ) { _ in
      openSettings()
    }
  }
}

@MainActor
private final class CodexBridgeAppDelegate: NSObject, NSApplicationDelegate {
  private weak var model: BridgeServiceAppModel?
  private var isClosingClient = false
  private var canTerminate = false

  func install(_ model: BridgeServiceAppModel) {
    self.model = model
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    if canTerminate || model?.isPreparedForUpdateTermination == true { return .terminateNow }
    if isClosingClient { return .terminateLater }
    guard let model else { return .terminateNow }
    isClosingClient = true
    let shouldRestoreVisibility = !sender.isHidden
    if shouldRestoreVisibility { sender.hide(nil) }
    Task {
      let stopped = await model.shutdownForApplicationTermination()
      canTerminate = stopped
      isClosingClient = false
      sender.reply(toApplicationShouldTerminate: stopped)
      if !stopped && shouldRestoreVisibility { sender.unhide(nil) }
    }
    return .terminateLater
  }
}
