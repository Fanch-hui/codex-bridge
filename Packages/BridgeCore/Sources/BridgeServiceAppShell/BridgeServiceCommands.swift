import AppKit
import SwiftUI

public struct BridgeServiceCommands: Commands {
  @ObservedObject private var model: BridgeServiceAppModel
  @Environment(\.openWindow) private var openWindow
  @Environment(\.openSettings) private var openSettings
  private let mainWindowID: String

  public init(model: BridgeServiceAppModel, mainWindowID: String) {
    self.model = model
    self.mainWindowID = mainWindowID
  }

  public var body: some Commands {
    CommandGroup(replacing: .newItem) {
      Button("新建对话") {
        model.requestNewConversation()
        show(.workbench)
      }
      .keyboardShortcut("n", modifiers: .command)

      Button("打开工作文件夹…") {
        show(.workbench)
        model.chooseWorkFolder()
      }
      .keyboardShortcut("o", modifiers: .command)
      .disabled(model.connectionState != .connected)
    }

    CommandGroup(replacing: .appSettings) {
      Button("设置…") {
        model.preferencesNavigation = .settings
        BridgeDesktopCommandRouter.loadNativePermissionPolicyIfNeeded(model)
        openSettings()
      }
      .keyboardShortcut(",", modifiers: .command)
    }

    CommandGroup(after: .sidebar) {
      Button("工作台") { show(.workbench) }
        .keyboardShortcut("1", modifiers: .command)
      Button("动态") { show(.overview) }
        .keyboardShortcut("2", modifiers: .command)
      Button("连接") { show(.connections) }
        .keyboardShortcut("3", modifiers: .command)
      Button("项目") { show(.projects) }
        .keyboardShortcut("4", modifiers: .command)

      Divider()

      Button("刷新当前页面") {
        if model.preferencesWindowIsKey {
          Task { await model.refreshCurrentPage(model.preferencesNavigation) }
        } else {
          model.refresh()
        }
      }
      .disabled(model.isRefreshing)
    }
  }

  private func show(_ navigation: BridgeServiceNavigation) {
    model.selection = navigation
    if !BridgeDesktopWindowCoordinator.shared.showMainWindow() {
      openWindow(id: mainWindowID)
    }
  }
}
