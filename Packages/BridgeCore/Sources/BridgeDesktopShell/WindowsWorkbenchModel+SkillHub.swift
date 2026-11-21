#if os(Windows) || os(Linux)
  import BridgeDesktopUI
  import BridgeIPC
  import Foundation

  private struct WindowsSkillHubPathInput: Decodable {
    let path: String
  }

  private struct WindowsSkillHubProjectInput: Decodable {
    let projectID: String?
  }

  private struct WindowsSkillHubImportPayload: Encodable {
    let path: String
    let projectID: String?
  }

  extension WindowsWorkbenchModel {
    func performSkillHub(_ envelope: BridgeDesktopCommandEnvelope) async {
      let requestID = envelope.requestID
      do {
        guard connectionState == .connected else { throw BridgeServiceClientError.unavailable }
        let value = try BridgeDesktopEmbeddedDSHCommand.request(envelope.payload)
        switch value.action {
        case "pickImportDirectory":
          pickSkillHubDirectory(
            requestID: requestID, targetAction: "importDirectory", rawPayloadJSON: value.payloadJSON
          )
        case "pickCustomDirectory":
          pickSkillHubDirectory(
            requestID: requestID, targetAction: "addCustomDirectory",
            rawPayloadJSON: value.payloadJSON)
        case "revealPath":
          let input = try JSONDecoder().decode(
            WindowsSkillHubPathInput.self, from: Data(value.payloadJSON.utf8))
          guard !input.path.isEmpty, !input.path.contains("\0"),
            FileManager.default.fileExists(atPath: input.path)
          else {
            throw NSError(
              domain: "BridgeSkillHub", code: 1,
              userInfo: [NSLocalizedDescriptionKey: "技能路径不存在或无效。"])
          }
          DesktopPlatformHost.revealInFileManager(input.path)
          appendEmbeddedDSHReceipt(
            .init(requestID: requestID, resultJSON: "{\"revealed\":true}"))
        default:
          let response = try await client.skillHub(
            IPCSkillHubRequest(action: value.action, payloadJSON: value.payloadJSON))
          refreshSkillHubWorkspaceIfMutated(action: value.action)
          appendEmbeddedDSHReceipt(.init(requestID: requestID, resultJSON: response.resultJSON))
        }
      } catch {
        appendEmbeddedDSHReceipt(.init(requestID: requestID, error: error))
      }
    }

    private func pickSkillHubDirectory(
      requestID: String,
      targetAction: String,
      rawPayloadJSON: String
    ) {
      DesktopPlatformHost.chooseSkillDirectory { [weak self] selectedPath in
        Task { @MainActor [weak self] in
          guard let self else { return }
          guard let path = selectedPath else {
            self.appendEmbeddedDSHReceipt(
              .init(requestID: requestID, resultJSON: "{\"cancelled\":true}"))
            return
          }
          do {
            guard self.connectionState == .connected else {
              throw BridgeServiceClientError.unavailable
            }
            let scope = try? JSONDecoder().decode(
              WindowsSkillHubProjectInput.self, from: Data(rawPayloadJSON.utf8))
            let payload = try JSONEncoder().encode(
              WindowsSkillHubImportPayload(path: path, projectID: scope?.projectID))
            let response = try await self.client.skillHub(
              IPCSkillHubRequest(
                action: targetAction,
                payloadJSON: String(decoding: payload, as: UTF8.self)))
            self.refreshSkillHubWorkspaceIfMutated(action: targetAction)
            self.appendEmbeddedDSHReceipt(
              .init(requestID: requestID, resultJSON: response.resultJSON))
          } catch {
            self.appendEmbeddedDSHReceipt(.init(requestID: requestID, error: error))
          }
        }
      }
    }

    func refreshSkillHubWorkspaceIfMutated(action: String) {
      let readOnly = ["snapshot", "preview", "diff"].contains(action)
      guard !readOnly else { return }
      Task { await workspaceModel.loadSelectedWorkspace() }
    }
  }
#endif
