import AppKit
import BridgeDesktopUI
import BridgeIPC
import BridgeServiceAppCore

extension BridgeDesktopCommandRouter {
  static func handleGeminiCloud(
    _ envelope: BridgeDesktopCommandEnvelope,
    model: BridgeServiceAppModel
  ) {
    guard connected(model) else { return }
    let payload = envelope.payload
    switch envelope.command {
    case .refreshGeminiCloud:
      Task { await model.refreshGeminiCloud() }
    case .configureGeminiCloud:
      guard let hosting = payload.mode.flatMap(IPCGeminiCloudHosting.init(rawValue:)),
        let baseURL = validatedText(payload.baseURL, maximumBytes: 4_096),
        let enabled = payload.enabled
      else { return }
      model.configureGeminiCloud(
        IPCGeminiCloudConfiguration(hosting: hosting, baseURL: baseURL, enabled: enabled))
    case .copyGeminiCloudConfiguration:
      guard let kind = payload.kind.flatMap(IPCGeminiCloudExportKind.init(rawValue:)) else {
        return
      }
      model.copyGeminiCloudConfiguration(kind: kind)
    default:
      return
    }
  }
}

extension BridgeServiceAppModel {
  func refreshGeminiCloud() async {
    guard let client else { return }
    do {
      geminiCloudStatus = try await client.geminiCloudStatus()
    } catch {
      errorMessage = Self.message(error)
    }
  }

  func configureGeminiCloud(_ configuration: IPCGeminiCloudConfiguration) {
    runMutation { [weak self] client in
      guard let self else { return }
      self.geminiCloudStatus = try await client.configureGeminiCloud(configuration)
      self.postToast(configuration.enabled ? "Gemini 云 MCP 配置已保存" : "Gemini 云 MCP 已停用")
    }
  }

  func copyGeminiCloudConfiguration(kind: IPCGeminiCloudExportKind) {
    runMutation { [weak self] client in
      let value = try await client.exportGeminiCloudConfiguration(kind: kind)
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(value, forType: .string)
      self?.postToast("已复制 Gemini 云 MCP 配置")
    }
  }
}
