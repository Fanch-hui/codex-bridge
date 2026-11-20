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

      ChatBrowserOverlay(model: model, viewportState: model.chatBrowserViewport)
        .zIndex(10)

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
    .ignoresSafeArea(.container, edges: .top)
    .navigationTitle("Codex Bridge")
    .task {
      model.start()
    }
    .alert(
      "操作失败",
      isPresented: Binding(
        get: { model.errorMessage != nil && !model.preferencesWindowIsKey },
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
  @Environment(\.openWindow) private var openWindow
  private let mainWindowID: String

  public init(model: BridgeServiceAppModel, mainWindowID: String = "main") {
    self.model = model
    self.mainWindowID = mainWindowID
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

      if model.approvals.count + model.directApprovals.count > 0 {
        Label(
          "等待处理 \(model.approvals.count + model.directApprovals.count) 项安全审批",
          systemImage: "exclamationmark.shield.fill"
        )
        .font(.caption)
        .foregroundStyle(.orange)
      }

      Divider()

      Button("打开管理") {
        showMainWindow()
      }

      Button("待处理审批") {
        model.selection = .overview
        if model.isLightweightMode == true {
          let coordinator = BridgeDesktopWindowCoordinator.shared
          let open = coordinator.showMainWindow()
          coordinator.openMain(destination: .init(kind: .lightweightActivity, value: ""))
          if !open { openWindow(id: mainWindowID) }
        } else {
          showMainWindow()
        }
      }

      Button(model.isModelGatewayEnabled == true ? "暂停模型网关" : "启动模型网关") {
        model.toggleModelGatewayFromTray()
      }

      Button(model.isLightweightMode == true ? "切换到完整模式" : "切换到轻量模式") {
        model.toggleApplicationModeFromTray()
      }

      Button("立即刷新状态") {
        model.refresh()
      }

      Divider()

      Button("退出应用程序") {
        NSApp.terminate(nil)
      }

      Button("彻底退出并停止后台服务") {
        showMainWindow()
        model.quitCompletely()
      }
    }
    .padding(10)
    .task {
      model.start()
    }
  }

  private func showMainWindow() {
    if !BridgeDesktopWindowCoordinator.shared.showMainWindow() {
      openWindow(id: mainWindowID)
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
