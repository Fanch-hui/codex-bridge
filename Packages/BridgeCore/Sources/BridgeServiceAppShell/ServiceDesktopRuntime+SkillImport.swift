import AppKit
import BridgeDesktopUI
import BridgeIPC

extension BridgeServiceAppModel {
  /// Lets the user choose a skill folder (or a folder of skills) and imports it into the
  /// workbench's global skill directory through the service.
  func importPickedSkills(requestID: String) async throws {
    let panel = NSOpenPanel()
    panel.title = "导入技能"
    panel.message = "选择包含 SKILL.md 的技能文件夹，或包含多个技能文件夹的上级文件夹"
    panel.prompt = "导入"
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    let accepted = await withCheckedContinuation { continuation in
      panel.begin { continuation.resume(returning: $0 == .OK) }
    }
    guard accepted, let url = panel.url else {
      appendEmbeddedDSHReceipt(.init(requestID: requestID, resultJSON: "{\"cancelled\":true}"))
      return
    }
    let payload = try JSONEncoder().encode(["path": url.standardizedFileURL.path])
    let response = try await currentClient().embeddedDSH(
      IPCEmbeddedDSHRequest(
        action: "skills.import", payloadJSON: String(decoding: payload, as: UTF8.self)))
    appendEmbeddedDSHReceipt(.init(requestID: requestID, resultJSON: response.resultJSON))
  }
}
