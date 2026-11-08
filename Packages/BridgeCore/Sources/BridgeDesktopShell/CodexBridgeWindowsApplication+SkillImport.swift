#if os(Windows) || os(Linux)
  import BridgeDesktopUI
  import BridgeIPC
  import Foundation

  extension CodexBridgeDesktopApplication {
    /// Lets the user choose a skill folder (or a folder of skills) and imports it into the
    /// workbench's global skill directory through the service.
    static func importPickedSkills(
      _ envelope: BridgeDesktopCommandEnvelope, model: WindowsWorkbenchModel
    ) {
      DesktopPlatformHost.chooseSkillDirectory { selectedPath in
        Task { @MainActor in
          guard let path = selectedPath else {
            model.appendEmbeddedDSHReceipt(
              .init(requestID: envelope.requestID, resultJSON: "{\"cancelled\":true}"))
            return
          }
          do {
            guard model.connectionState == .connected else {
              throw BridgeServiceClientError.unavailable
            }
            let payload = try JSONEncoder().encode(["path": path])
            let response = try await model.client.embeddedDSH(
              IPCEmbeddedDSHRequest(
                action: "skills.import", payloadJSON: String(decoding: payload, as: UTF8.self)))
            model.appendEmbeddedDSHReceipt(
              .init(requestID: envelope.requestID, resultJSON: response.resultJSON))
          } catch {
            model.appendEmbeddedDSHReceipt(.init(requestID: envelope.requestID, error: error))
          }
        }
      }
    }
  }
#endif
