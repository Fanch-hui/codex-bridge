#if os(Windows) || os(Linux)
  import BridgeDesktopUI
  import BridgeIPC
  import BridgeServiceAppCore
  import Foundation

  extension CodexBridgeDesktopApplication {
    static func exportWorkbenchContent(
      _ envelope: BridgeDesktopCommandEnvelope, model: WindowsWorkbenchModel
    ) {
      do {
        let value = try BridgeDesktopEmbeddedDSHCommand.request(envelope.payload)
        let request = try WorkbenchContentExport.request(from: value.payloadJSON)
        DesktopPlatformHost.chooseSaveFile { path in
          Task { @MainActor in
            guard let path else {
              model.appendEmbeddedDSHReceipt(
                .init(
                  requestID: envelope.requestID,
                  resultJSON: "{\"cancelled\":true}"))
              return
            }
            do {
              try await WorkbenchContentExport.export(
                request, to: URL(fileURLWithPath: path), client: model.client)
              model.appendEmbeddedDSHReceipt(
                .init(
                  requestID: envelope.requestID,
                  resultJSON: "{\"saved\":true}"))
            } catch {
              model.appendEmbeddedDSHReceipt(.init(requestID: envelope.requestID, error: error))
            }
          }
        }
      } catch {
        model.appendEmbeddedDSHReceipt(.init(requestID: envelope.requestID, error: error))
      }
    }

    static func pickWorkbenchAttachment(
      _ envelope: BridgeDesktopCommandEnvelope,
      model: WindowsWorkbenchModel
    ) {
      DesktopPlatformHost.chooseImageFile { selectedPath in
        Task { @MainActor in
          do {
            guard let selectedPath else {
              model.appendEmbeddedDSHReceipt(
                .init(
                  requestID: envelope.requestID,
                  resultJSON: "{\"attachmentRefs\":[],\"items\":[],\"cancelled\":true}"))
              return
            }
            let result = try await WorkbenchSelectedAttachment.importSelected(
              at: selectedPath, client: model.client)
            model.appendEmbeddedDSHReceipt(
              .init(requestID: envelope.requestID, resultJSON: result))
          } catch {
            model.appendEmbeddedDSHReceipt(.init(requestID: envelope.requestID, error: error))
          }
        }
      }
    }

    static func pickWorkbenchWorkspace(
      _ envelope: BridgeDesktopCommandEnvelope,
      model: WindowsWorkbenchModel,
      management: WindowsManagementModel
    ) {
      DesktopPlatformHost.chooseWorkspaceDirectory { selectedPath in
        Task { @MainActor in
          guard let path = selectedPath else {
            model.appendEmbeddedDSHReceipt(
              .init(
                requestID: envelope.requestID,
                resultJSON: "{\"cancelled\":true}"))
            return
          }
          let existing = management.projectPaths.first { $0.value == path }?.key
          let projectID: String?
          if let existing {
            projectID = existing
          } else {
            projectID = await management.registerProject(
              name: URL(fileURLWithPath: path).lastPathComponent, path: path)
          }
          guard let projectID else {
            model.appendEmbeddedDSHReceipt(
              .init(
                requestID: envelope.requestID,
                error: BridgeDesktopAttachmentSelection.Failure.projectUnavailable))
            return
          }
          do {
            let json = try JSONEncoder().encode(["projectID": projectID])
            model.appendEmbeddedDSHReceipt(
              .init(
                requestID: envelope.requestID,
                resultJSON: String(decoding: json, as: UTF8.self)))
          } catch {
            model.appendEmbeddedDSHReceipt(.init(requestID: envelope.requestID, error: error))
          }
        }
      }
    }
  }
#endif
