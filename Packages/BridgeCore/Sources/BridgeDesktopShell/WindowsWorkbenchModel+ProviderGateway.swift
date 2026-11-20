#if os(Windows) || os(Linux)
  import BridgeDesktopUI
  import BridgeIPC
  import BridgeServiceAppCore
  import Foundation

  private struct ProviderGatewayConfiguration: Decodable {
    let configuration: String
  }

  private struct ProviderGatewayMode: Decodable {
    enum Mode: String, Decodable { case full, lite }
    struct Gateway: Decodable { let enabled: Bool }
    let mode: Mode
    let transition: String?
    let error: String?
    let gateway: Gateway
  }

  private enum ProviderGatewayCopyError: LocalizedError {
    case invalidAction
    case clipboardUnavailable
    case protectedConfiguration

    var errorDescription: String? {
      switch self {
      case .invalidAction, .protectedConfiguration: return "请使用复制操作获取应用配置。"
      case .clipboardUnavailable: return "剪贴板不可用。"
      }
    }
  }

  extension WindowsWorkbenchModel {
    @discardableResult
    func applyServiceStatusMode(_ status: IPCServiceStatusResponse) -> Bool {
      guard let raw = status.applicationMode, raw == "full" || raw == "lite" else { return false }
      return applyApplicationMode(
        lightweight: raw == "lite",
        transition: status.applicationModeTransition,
        error: status.applicationModeError,
        gatewayEnabled: status.modelGatewayRunning
      )
    }

    func refreshProviderGatewayModeStatus() async throws {
      do {
        let gateway = try await client.providerGateway(
          IPCProviderGatewayRequest(action: "mode.status"))
        try applyProviderGatewayStatus(gateway.resultJSON)
      } catch {
        guard BridgeServiceErrorMessage.remoteFailure(error)?.code == "invalid_state" else {
          throw error
        }
        let gateway = try await client.providerGateway(
          IPCProviderGatewayRequest(action: "status"))
        try applyProviderGatewayStatus(gateway.resultJSON)
      }
    }

    func applyProviderGatewayStatus(_ resultJSON: String) throws {
      let mode = try JSONDecoder().decode(ProviderGatewayMode.self, from: Data(resultJSON.utf8))
      if applyApplicationMode(
        lightweight: mode.mode == .lite,
        transition: mode.transition,
        error: mode.error,
        gatewayEnabled: mode.gateway.enabled
      ) {
        publishDisplay()
      }
    }

    @discardableResult
    private func applyApplicationMode(
      lightweight: Bool,
      transition: String?,
      error: String?,
      gatewayEnabled: Bool?
    ) -> Bool {
      var changed = false
      if let gatewayEnabled, isModelGatewayEnabled != gatewayEnabled {
        isModelGatewayEnabled = gatewayEnabled
      }
      if applicationModeTransition != transition {
        applicationModeTransition = transition
        changed = true
      }
      if applicationModeError != error {
        applicationModeError = error
        changed = true
      }
      let wasLightweight = isLightweightMode
      guard wasLightweight != lightweight else { return changed }
      isLightweightMode = lightweight
      lightweightModeDidChange(from: wasLightweight)
      CodexBridgeDesktopApplication.updateBrowserMemoryPolicy(model: self)
      return true
    }

    func performProviderGateway(_ envelope: BridgeDesktopCommandEnvelope) async {
      let receipt: BridgeDesktopEmbeddedDSHReceipt
      do {
        guard connectionState == .connected else { throw BridgeServiceClientError.unavailable }
        let value = try BridgeDesktopEmbeddedDSHCommand.request(envelope.payload)
        guard value.action != "clients.configuration" else {
          throw ProviderGatewayCopyError.protectedConfiguration
        }
        let response = try await client.providerGateway(
          IPCProviderGatewayRequest(action: value.action, payloadJSON: value.payloadJSON))
        if ["status", "mode.status", "mode.set", "mode.cancel", "onboarding.complete"].contains(
          value.action)
        {
          try applyProviderGatewayStatus(response.resultJSON)
        }
        receipt = .init(requestID: envelope.requestID, resultJSON: response.resultJSON)
      } catch {
        receipt = .init(requestID: envelope.requestID, error: error)
      }
      appendEmbeddedDSHReceipt(receipt)
    }

    func copyProviderGatewayConnection(_ envelope: BridgeDesktopCommandEnvelope) async {
      let receipt: BridgeDesktopEmbeddedDSHReceipt
      do {
        guard connectionState == .connected else { throw BridgeServiceClientError.unavailable }
        let value = try BridgeDesktopEmbeddedDSHCommand.request(envelope.payload)
        guard value.action == "clients.configuration" else {
          throw ProviderGatewayCopyError.invalidAction
        }
        let response = try await client.providerGateway(
          IPCProviderGatewayRequest(action: value.action, payloadJSON: value.payloadJSON))
        let result = try JSONDecoder().decode(
          ProviderGatewayConfiguration.self, from: Data(response.resultJSON.utf8))
        guard DesktopPlatformHost.copy(result.configuration) else {
          throw ProviderGatewayCopyError.clipboardUnavailable
        }
        receipt = .init(requestID: envelope.requestID, resultJSON: "{\"copied\":true}")
      } catch {
        receipt = .init(requestID: envelope.requestID, error: error)
      }
      appendEmbeddedDSHReceipt(receipt)
    }
  }
#endif
