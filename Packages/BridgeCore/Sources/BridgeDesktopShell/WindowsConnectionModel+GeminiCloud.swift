#if os(Windows) || os(Linux)
  import BridgeDesktopUI
  import BridgeIPC
  import BridgeServiceAppCore

  extension WindowsConnectionModel {
    var projectedGeminiCloud: BridgeDesktopGeminiCloudState {
      let enabled = clients.first { $0.clientID == "google.gemini" }?.enabled == true
      return BridgeDesktopGeminiCloudState(
        hosting: geminiCloudStatus?.configuration?.hosting.rawValue ?? "sites",
        baseURL: geminiCloudStatus?.configuration?.baseURL ?? "",
        enabled: geminiCloudStatus?.configuration?.enabled ?? false,
        lifecycle: geminiCloudStatus?.lifecycle ?? "stopped",
        message: geminiCloudStatus?.message,
        lastConnectedAt: geminiCloudStatus?.lastConnectedAt,
        canConfigure: connectionState == .connected && enabled && !busy,
        canExport: connectionState == .connected && enabled && !busy
      )
    }

    func refreshGeminiCloud() async {
      guard connectionState == .connected, !busy else { return }
      do {
        geminiCloudStatus = try await client.geminiCloudStatus()
      } catch {
        statusText = BridgeServiceErrorMessage.message(error)
      }
      publishDisplay()
    }

    func configureGeminiCloud(_ configuration: IPCGeminiCloudConfiguration) async {
      await mutate("正在保存 Gemini 云 MCP…", success: "Gemini 云 MCP 配置已保存。") {
        self.geminiCloudStatus = try await self.client.configureGeminiCloud(configuration)
      }
    }

    func copyGeminiCloudConfiguration(kind: IPCGeminiCloudExportKind) async {
      guard connectionState == .connected, !busy else { return }
      do {
        let value = try await client.exportGeminiCloudConfiguration(kind: kind)
        if DesktopPlatformHost.copy(value) {
          feedback.postToast("已复制 Gemini 云 MCP 配置")
        } else {
          feedback.postAlert("无法写入剪贴板。", title: "复制失败")
        }
      } catch {
        statusText = BridgeServiceErrorMessage.message(error)
        feedback.postAlert(statusText, title: "复制失败")
      }
      publishDisplay()
    }
  }

  extension CodexBridgeDesktopApplication {
    static func runDesktopGeminiCloudCommand(
      _ envelope: BridgeDesktopCommandEnvelope,
      connections: WindowsConnectionModel
    ) -> Bool {
      let payload = envelope.payload
      switch envelope.command {
      case .refreshGeminiCloud:
        Task { @MainActor in await connections.refreshGeminiCloud() }
      case .configureGeminiCloud:
        guard let hosting = payload.mode.flatMap(IPCGeminiCloudHosting.init(rawValue:)),
          let baseURL = BridgeDesktopCommandValue.text(payload.baseURL, maximumUTF8Bytes: 4_096),
          let enabled = payload.enabled
        else { return true }
        Task { @MainActor in
          await connections.configureGeminiCloud(
            IPCGeminiCloudConfiguration(hosting: hosting, baseURL: baseURL, enabled: enabled))
        }
      case .copyGeminiCloudConfiguration:
        guard let kind = payload.kind.flatMap(IPCGeminiCloudExportKind.init(rawValue:)) else {
          return true
        }
        Task { @MainActor in await connections.copyGeminiCloudConfiguration(kind: kind) }
      default:
        return false
      }
      return true
    }
  }
#endif
