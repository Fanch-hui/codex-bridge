import AppKit
import SwiftUI

public struct BridgeServiceCommands: Commands {
  @ObservedObject private var model: BridgeServiceAppModel
  @Environment(\.openWindow) private var openWindow
  private let mainWindowID: String

  public init(model: BridgeServiceAppModel, mainWindowID: String) {
    self.model = model
    self.mainWindowID = mainWindowID
  }

  public var body: some Commands {
    CommandGroup(replacing: .appSettings) {
      Button("设置…") { show(.settings) }
        .keyboardShortcut(",", modifiers: .command)
    }

    CommandGroup(after: .sidebar) {
      Button("概览") { show(.overview) }
        .keyboardShortcut("1", modifiers: .command)
      Button("连接") { show(.connections) }
        .keyboardShortcut("2", modifiers: .command)
      Button("项目") { show(.projects) }
        .keyboardShortcut("3", modifiers: .command)
      Button("工作台") { show(.workbench) }
        .keyboardShortcut("4", modifiers: .command)

      Divider()

      Button("刷新当前页面") { model.refresh() }
        .disabled(model.isRefreshing)
    }
  }

  private func show(_ navigation: BridgeServiceNavigation) {
    model.selection = navigation
    NSApp.activate(ignoringOtherApps: true)
    if let window = NSApp.mainWindow ?? NSApp.windows.first(where: \.canBecomeMain) {
      window.makeKeyAndOrderFront(nil)
    } else {
      openWindow(id: mainWindowID)
    }
  }
}
