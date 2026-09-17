import AppKit
import BridgeServiceAppCore
import SwiftUI

public struct BridgeServiceRootView: View {
  @ObservedObject private var model: BridgeServiceAppModel

  public init(model: BridgeServiceAppModel) {
    self.model = model
  }

  public var body: some View {
    ZStack(alignment: .topLeading) {
      BridgeDesktopWebView(model: model)

      if let viewport = model.chatBrowserViewport,
        viewport.visible,
        model.navigation == .workbench,
        model.isChatBrowserEnabled
      {
        ChatGPTWebView(
          initialURL: model.chatBrowserResumeURL,
          reloadRequest: model.chatBrowserReloadRequest,
          webViewReference: $model.chatWebView
        )
        .frame(width: viewport.width, height: viewport.height)
        .offset(x: viewport.x, y: viewport.y)
        .zIndex(10)
      }

      if let toast = model.toast {
        ToastHUDView(toast: toast) {
          model.clearToast()
        }
        .padding(.trailing, 24)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .zIndex(100)
      }
    }
    .navigationTitle("Codex Bridge")
    .task {
      model.start()
    }
    .alert(
      "操作失败",
      isPresented: Binding(
        get: { model.errorMessage != nil },
        set: { visible in
          if !visible { model.errorMessage = nil }
        }
      )
    ) {
      Button("好", role: .cancel) {
        model.errorMessage = nil
      }
    } message: {
      Text(model.errorMessage ?? "未知错误")
    }
  }

}

public struct BridgeServiceMenuBarView: View {
  @ObservedObject private var model: BridgeServiceAppModel

  public init(model: BridgeServiceAppModel) {
    self.model = model
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 6) {
        Circle()
          .fill(menuStatusColor)
          .frame(width: 8, height: 8)
        Text("Codex Bridge · \(model.connectionState.label)")
          .font(.subheadline.weight(.semibold))
      }

      if model.runningTaskCount > 0 {
        Label("正在运行 \(model.runningTaskCount) 个任务", systemImage: "bolt.fill")
          .font(.caption)
          .foregroundStyle(.green)
      }

      if model.approvals.count > 0 {
        Label("等待处理 \(model.approvals.count) 项安全审批", systemImage: "exclamationmark.shield.fill")
          .font(.caption)
          .foregroundStyle(.orange)
      }

      Divider()

      Button("打开工作台") {
        model.selection = .workbench
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first(where: \.canBecomeMain)?.makeKeyAndOrderFront(nil)
      }

      Button("打开主窗口") {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first(where: \.canBecomeMain)?.makeKeyAndOrderFront(nil)
      }

      Button("立即刷新状态") {
        model.refresh()
      }

      Divider()

      Button("退出应用程序") {
        NSApp.terminate(nil)
      }
    }
    .padding(10)
    .task {
      model.start()
    }
  }

  private var menuStatusColor: Color {
    switch model.connectionState {
    case .connected: .green
    case .registering, .connecting: .orange
    case .requiresApproval: .orange
    case .idle, .unavailable: .red
    }
  }
}
