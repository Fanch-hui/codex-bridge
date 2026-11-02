import AppKit
import BridgeDesktopUI
import BridgeIPC
import BridgeServiceAppCore
import UniformTypeIdentifiers

extension BridgeServiceAppModel {
  func performEmbeddedDSH(_ envelope: BridgeDesktopCommandEnvelope) {
    let requestID = envelope.requestID
    Task { [weak self] in
      guard let self else { return }
      do {
        let value = try BridgeDesktopEmbeddedDSHCommand.request(envelope.payload)
        if value.action == "workspace.pick" {
          let panel = NSOpenPanel()
          panel.title = "打开工作文件夹"
          panel.canChooseFiles = false
          panel.canChooseDirectories = true
          let accepted = await withCheckedContinuation { continuation in
            panel.begin { continuation.resume(returning: $0 == .OK) }
          }
          guard accepted, let url = panel.url else {
            self.appendEmbeddedDSHReceipt(
              .init(
                requestID: requestID,
                resultJSON: "{\"cancelled\":true}"))
            return
          }
          let client = try self.currentClient()
          let existing = self.projectPaths.first {
            URL(fileURLWithPath: $0.value).standardizedFileURL == url.standardizedFileURL
          }?.key
          let projectID: String
          if let existing {
            projectID = existing
          } else {
            projectID = try await client.registerProject(
              .init(
                name: url.lastPathComponent, absolutePath: url.standardizedFileURL.path)
            ).projectID
          }
          await self.refresh(silent: true, includeCatalog: false)
          self.selectProject(projectID)
          let data = try JSONEncoder().encode(["projectID": projectID])
          self.appendEmbeddedDSHReceipt(
            .init(
              requestID: requestID,
              resultJSON: String(decoding: data, as: UTF8.self)))
          return
        }
        if value.action == "attachments.pick" {
          let panel = NSOpenPanel()
          panel.title = "添加图片"
          panel.canChooseFiles = true
          panel.canChooseDirectories = false
          panel.allowsMultipleSelection = false
          panel.allowedContentTypes =
            [.png, .jpeg] + [UTType(filenameExtension: "webp")].compactMap { $0 }
          let accepted = await withCheckedContinuation { continuation in
            panel.begin { continuation.resume(returning: $0 == .OK) }
          }
          guard accepted, let path = panel.url?.path else {
            self.appendEmbeddedDSHReceipt(
              .init(
                requestID: requestID,
                resultJSON: "{\"attachmentRefs\":[],\"items\":[],\"cancelled\":true}"))
            return
          }
          let result = try await WorkbenchSelectedAttachment.importSelected(
            at: path, client: self.currentClient())
          self.appendEmbeddedDSHReceipt(.init(requestID: requestID, resultJSON: result))
          return
        }
        if value.action == "content.export" {
          let request = try WorkbenchContentExport.request(from: value.payloadJSON)
          let panel = NSSavePanel()
          panel.title = "导出会话内容"
          panel.nameFieldStringValue = "会话内容.txt"
          panel.canCreateDirectories = true
          let accepted = await withCheckedContinuation { continuation in
            panel.begin { continuation.resume(returning: $0 == .OK) }
          }
          guard accepted, let url = panel.url else {
            self.appendEmbeddedDSHReceipt(
              .init(
                requestID: requestID,
                resultJSON: "{\"cancelled\":true}"))
            return
          }
          try await WorkbenchContentExport.export(request, to: url, client: self.currentClient())
          self.appendEmbeddedDSHReceipt(.init(requestID: requestID, resultJSON: "{\"saved\":true}"))
          return
        }
        let response = try await self.currentClient().embeddedDSH(
          IPCEmbeddedDSHRequest(action: value.action, payloadJSON: value.payloadJSON))
        self.appendEmbeddedDSHReceipt(.init(requestID: requestID, resultJSON: response.resultJSON))
      } catch {
        self.appendEmbeddedDSHReceipt(.init(requestID: requestID, error: error))
      }
    }
  }

  private func appendEmbeddedDSHReceipt(_ receipt: BridgeDesktopEmbeddedDSHReceipt) {
    embeddedDSHReceipts.append(receipt)
    if embeddedDSHReceipts.count > 32 { embeddedDSHReceipts.removeFirst() }
  }
}
