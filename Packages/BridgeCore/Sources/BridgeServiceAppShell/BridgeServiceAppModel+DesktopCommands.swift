import AppKit
import Foundation

extension BridgeServiceAppModel {
  func requestNewConversation() {
    selection = .workbench
    pendingNewConversationRequestID = UUID()
  }

  func acknowledgeNewConversation(_ requestID: UUID) {
    guard pendingNewConversationRequestID == requestID else { return }
    pendingNewConversationRequestID = nil
  }

  func chooseWorkFolder() {
    guard connectionState == .connected else { return }
    let panel = NSOpenPanel()
    panel.title = "选择工作文件夹"
    panel.prompt = "打开"
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    guard panel.runModal() == .OK, let url = panel.url else { return }
    registerProject(at: url)
  }
}
