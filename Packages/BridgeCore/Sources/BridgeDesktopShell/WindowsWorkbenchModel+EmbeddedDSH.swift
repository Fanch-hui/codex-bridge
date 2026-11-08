#if os(Windows) || os(Linux)
  import BridgeDesktopUI
  import BridgeIPC

  extension WindowsWorkbenchModel {
    func performEmbeddedDSH(_ envelope: BridgeDesktopCommandEnvelope) async {
      let receipt: BridgeDesktopEmbeddedDSHReceipt
      do {
        guard connectionState == .connected else { throw BridgeServiceClientError.unavailable }
        let value = try BridgeDesktopEmbeddedDSHCommand.request(envelope.payload)
        let response = try await client.embeddedDSH(
          IPCEmbeddedDSHRequest(action: value.action, payloadJSON: value.payloadJSON))
        receipt = .init(requestID: envelope.requestID, resultJSON: response.resultJSON)
      } catch {
        receipt = .init(requestID: envelope.requestID, error: error)
      }
      appendEmbeddedDSHReceipt(receipt)
    }

    func appendEmbeddedDSHReceipt(_ receipt: BridgeDesktopEmbeddedDSHReceipt) {
      embeddedDSHReceipts.append(receipt)
      if embeddedDSHReceipts.count > 32 { embeddedDSHReceipts.removeFirst() }
      publishDisplay()
    }
  }
#endif
