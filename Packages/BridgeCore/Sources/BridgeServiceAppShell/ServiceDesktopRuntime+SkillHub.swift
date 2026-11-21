import AppKit
import BridgeAgentCore
import BridgeDesktopUI
import BridgeIPC
import Foundation

private struct SkillHubPathInput: Codable {
  let path: String
}

private struct SkillHubImportPayload: Encodable {
  let path: String
  let projectID: String?
}

private struct SkillHubProjectOnlyInput: Decodable {
  let projectID: String?
}

extension BridgeServiceAppModel {
  func performSkillHub(_ envelope: BridgeDesktopCommandEnvelope) {
    let requestID = envelope.requestID
    Task { [weak self] in
      guard let self else { return }
      do {
        let value = try BridgeDesktopEmbeddedDSHCommand.request(envelope.payload)
        switch value.action {
        case "pickImportDirectory":
          try await self.pickAndForwardSkillHubDirectory(
            requestID: requestID,
            title: "导入技能",
            message: "选择包含 SKILL.md 的技能文件夹，或包含多个技能文件夹的上级文件夹",
            prompt: "导入",
            targetAction: "importDirectory",
            rawPayloadJSON: value.payloadJSON
          )
        case "pickCustomDirectory":
          try await self.pickAndForwardSkillHubDirectory(
            requestID: requestID,
            title: "添加自定义技能目录",
            message: "选择包含技能文件夹的目录（Bridge 对外部目录保持只读）",
            prompt: "添加",
            targetAction: "addCustomDirectory",
            rawPayloadJSON: value.payloadJSON
          )
        case "revealPath":
          let input = try JSONDecoder().decode(
            SkillHubPathInput.self, from: Data(value.payloadJSON.utf8))
          guard AgentPathSemantics.isAbsolute(input.path),
            FileManager.default.fileExists(atPath: input.path)
          else {
            throw NSError(
              domain: "BridgeSkillHub", code: 1,
              userInfo: [NSLocalizedDescriptionKey: "技能路径不存在或无效。"])
          }
          NSWorkspace.shared.activateFileViewerSelecting([
            URL(fileURLWithPath: input.path).standardizedFileURL
          ])
          self.appendEmbeddedDSHReceipt(
            .init(requestID: requestID, resultJSON: "{\"revealed\":true}"))
        default:
          let response = try await self.currentClient().skillHub(
            IPCSkillHubRequest(action: value.action, payloadJSON: value.payloadJSON))
          self.refreshSelectedProjectSkillsIfMutated(action: value.action)
          self.appendEmbeddedDSHReceipt(
            .init(requestID: requestID, resultJSON: response.resultJSON))
        }
      } catch {
        self.appendEmbeddedDSHReceipt(.init(requestID: requestID, error: error))
      }
    }
  }

  private func pickAndForwardSkillHubDirectory(
    requestID: String,
    title: String,
    message: String,
    prompt: String,
    targetAction: String,
    rawPayloadJSON: String
  ) async throws {
    let panel = NSOpenPanel()
    panel.title = title
    panel.message = message
    panel.prompt = prompt
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
    let scope = try? JSONDecoder().decode(
      SkillHubProjectOnlyInput.self, from: Data(rawPayloadJSON.utf8))
    let forwardPayload = SkillHubImportPayload(
      path: url.standardizedFileURL.path, projectID: scope?.projectID)
    let encoded = try JSONEncoder().encode(forwardPayload)
    let response = try await currentClient().skillHub(
      IPCSkillHubRequest(
        action: targetAction,
        payloadJSON: String(decoding: encoded, as: UTF8.self)))
    refreshSelectedProjectSkillsIfMutated(action: targetAction)
    appendEmbeddedDSHReceipt(.init(requestID: requestID, resultJSON: response.resultJSON))
  }

  func refreshSelectedProjectSkillsIfMutated(action: String) {
    let readOnly = ["snapshot", "preview", "diff"].contains(action)
    guard !readOnly, let projectID = selectedProjectID else { return }
    loadSkills(projectID: projectID)
  }
}
