import AppKit
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

extension BridgeServiceAppModel {
  func applyServiceStatusMode(_ status: IPCServiceStatusResponse) {
    guard let raw = status.applicationMode, raw == "full" || raw == "lite" else { return }
    applyApplicationMode(
      lightweight: raw == "lite",
      transition: status.applicationModeTransition,
      error: status.applicationModeError,
      gatewayEnabled: status.modelGatewayRunning
    )
  }

  func refreshProviderGatewayModeStatus(
    using client: any BridgeServiceClientProtocol
  ) async throws {
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
    applyApplicationMode(
      lightweight: mode.mode == .lite,
      transition: mode.transition,
      error: mode.error,
      gatewayEnabled: mode.gateway.enabled
    )
  }

  private func applyApplicationMode(
    lightweight: Bool,
    transition: String?,
    error: String?,
    gatewayEnabled: Bool?
  ) {
    if let gatewayEnabled, isModelGatewayEnabled != gatewayEnabled {
      isModelGatewayEnabled = gatewayEnabled
    }
    if applicationModeTransition != transition {
      applicationModeTransition = transition
    }
    if applicationModeError != error {
      applicationModeError = error
    }
    guard isLightweightMode != lightweight else { return }
    isLightweightMode = lightweight
    lightweightModeDidChange()
    if lightweight {
      cancelChatBrowserSleep()
      chatBrowserViewport.update(nil)
      if chatBrowserSessions.hasWebViews { releaseChatWebView() }
    }
  }

  func performProviderGateway(_ envelope: BridgeDesktopCommandEnvelope) {
    Task { [weak self] in
      guard let self else { return }
      do {
        let value = try BridgeDesktopEmbeddedDSHCommand.request(envelope.payload)
        guard value.action != "clients.configuration" else {
          throw ProviderGatewayCopyError.protectedConfiguration
        }
        let response = try await self.currentClient().providerGateway(
          IPCProviderGatewayRequest(action: value.action, payloadJSON: value.payloadJSON))
        if ["status", "mode.status", "mode.set", "mode.cancel", "onboarding.complete"].contains(
          value.action)
        {
          try self.applyProviderGatewayStatus(response.resultJSON)
        }
        self.appendEmbeddedDSHReceipt(
          .init(requestID: envelope.requestID, resultJSON: response.resultJSON))
      } catch {
        self.appendEmbeddedDSHReceipt(.init(requestID: envelope.requestID, error: error))
      }
    }
  }

  func copyProviderGatewayConnection(_ envelope: BridgeDesktopCommandEnvelope) {
    Task { [weak self] in
      guard let self else { return }
      do {
        let value = try BridgeDesktopEmbeddedDSHCommand.request(envelope.payload)
        guard value.action == "clients.configuration" else {
          throw ProviderGatewayCopyError.invalidAction
        }
        let response = try await self.currentClient().providerGateway(
          IPCProviderGatewayRequest(action: value.action, payloadJSON: value.payloadJSON))
        let result = try JSONDecoder().decode(
          ProviderGatewayConfiguration.self, from: Data(response.resultJSON.utf8))
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(result.configuration, forType: .string) else {
          throw ProviderGatewayCopyError.clipboardUnavailable
        }
        self.appendEmbeddedDSHReceipt(
          .init(requestID: envelope.requestID, resultJSON: "{\"copied\":true}"))
      } catch {
        self.appendEmbeddedDSHReceipt(.init(requestID: envelope.requestID, error: error))
      }
    }
  }
}
