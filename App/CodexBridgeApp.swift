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
    }
    .defaultSize(width: 1180, height: 760)
    .commands {
      BridgeServiceCommands(model: model, mainWindowID: Self.mainWindowID)
    }

    MenuBarExtra {
      BridgeServiceMenuBarView(model: model)
    } label: {
      Label("Codex Bridge", systemImage: "link")
        .accessibilityLabel("Codex Bridge")
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
    guard !isClosingClient, let model else { return .terminateNow }
    isClosingClient = true
    Task {
      await model.shutdownForApplicationTermination()
      canTerminate = true
      sender.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }
}
