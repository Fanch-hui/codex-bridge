import AppKit
import SwiftUI

public struct BridgeServicePreferencesView: View {
  @ObservedObject private var model: BridgeServiceAppModel
  @Environment(\.openWindow) private var openWindow
  private let mainWindowID: String

  public init(model: BridgeServiceAppModel, mainWindowID: String) {
    self.model = model
    self.mainWindowID = mainWindowID
  }

  public var body: some View {
    ZStack(alignment: .bottomTrailing) {
      BridgeDesktopWebView(model: model, surface: .preferences)
      if let toast = model.toast {
        ToastHUDView(toast: toast) { model.clearToast() }
          .padding(20)
      }
    }
    .frame(minWidth: 720, idealWidth: 860, minHeight: 500, idealHeight: 620)
    .navigationTitle(model.preferencesNavigation == .logs ? "日志" : "设置")
    .onAppear { model.preferencesWindowDidAppear() }
    .task {
      model.start()
      BridgeDesktopCommandRouter.loadNativePermissionPolicyIfNeeded(model)
    }
    .onChange(of: model.connectionState) { _, state in
      if state == .connected {
        BridgeDesktopCommandRouter.loadNativePermissionPolicyIfNeeded(model)
        Task { await model.refreshVisiblePreferences() }
      }
    }
    .onReceive(
      NotificationCenter.default.publisher(for: BridgeDesktopWindowNotifications.openMain)
    ) { _ in
      openWindow(id: mainWindowID)
      NSApp.activate(ignoringOtherApps: true)
    }
    .onDisappear { model.preferencesWindowDidDisappear() }
    .alert(
      "操作失败",
      isPresented: Binding(
        get: { model.errorMessage != nil && model.preferencesWindowIsKey },
        set: { visible in
          if !visible { model.errorMessage = nil }
        }
      )
    ) {
      Button("好", role: .cancel) { model.errorMessage = nil }
    } message: {
      Text(model.errorMessage ?? "未知错误")
    }
  }
}
