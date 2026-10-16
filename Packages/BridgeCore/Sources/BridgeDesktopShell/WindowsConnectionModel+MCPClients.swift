#if os(Windows) || os(Linux)
  import BridgeMCP
  import BridgeServiceAppCore

  extension WindowsConnectionModel {
    func toggleSelectedClient(clientID: String? = nil) async {
      guard let profile = profile(clientID: clientID),
        Self.isLocalClient(profile.clientID)
      else {
        return
      }
      let enabled = !profile.enabled
      await mutate(
        "正在更新 \(profile.displayName) 状态…",
        success: enabled ? "\(profile.displayName) 已启用。" : "\(profile.displayName) 已停用。"
      ) {
        try await self.client.setMCPClientEnabled(
          clientID: profile.clientID,
          enabled: enabled
        )
      }
    }

    func setSelectedExposure(at index: Int, clientID: String? = nil) async {
      guard Self.exposureModes.indices.contains(index), let profile = profile(clientID: clientID)
      else { return }
      let mode = Self.exposureModes[index]
      await mutate(
        "正在保存工具权限…",
        success: "工具权限已设置为：\(mode == .full ? "完整" : "只读")。"
      ) {
        if profile.clientID == MCPClientID.chatGPT.rawValue {
          try await self.client.setExposureMode(mode)
        } else {
          try await self.client.setMCPClientExposureMode(clientID: profile.clientID, mode: mode)
        }
      }
    }

    func exportSelectedConfiguration(clientID: String? = nil) async -> String? {
      guard let profile = profile(clientID: clientID),
        Self.isLocalClient(profile.clientID),
        profile.enabled
      else { return nil }
      do {
        let value: String
        if profile.clientID == MCPClientID.gemini.rawValue {
          value = try GeminiLocalMCPCommand.command()
          statusText = "Gemini 本地 MCP 启动命令已生成。"
        } else {
          value = try await client.exportMCPClientConfiguration(clientID: profile.clientID)
          statusText = "Qwen JSON 配置已生成。"
        }
        publishDisplay()
        return value
      } catch {
        statusText = "生成 \(profile.displayName) 配置失败：\(BridgeServiceErrorMessage.message(error))"
        feedback.postAlert(statusText, title: "配置生成失败")
        publishDisplay()
        return nil
      }
    }

    func rotateSelectedCredential(clientID: String? = nil) async {
      guard let profile = profile(clientID: clientID),
        Self.isLocalClient(profile.clientID),
        profile.enabled
      else { return }
      let success =
        profile.clientID == MCPClientID.gemini.rawValue
        ? "Gemini 连接已重置，请在 Gemini 中重新连接。" : "Qwen 凭证已重新生成。"
      await mutate("正在重置 \(profile.displayName) 连接…", success: success) {
        try await self.client.rotateMCPClientCredential(clientID: profile.clientID)
      }
    }

    func didCopyConfiguration(_ success: Bool, clientID: String? = nil) {
      let gemini = (clientID ?? selectedClientID) == MCPClientID.gemini.rawValue
      let title = gemini ? "Gemini 本地 MCP 启动命令" : "Qwen Studio JSON 配置"
      statusText = success ? "已复制\(title)。" : "复制\(title)失败。"
      if success {
        feedback.postToast(statusText)
      } else {
        feedback.postAlert(statusText, title: "复制失败")
      }
      publishDisplay()
    }

    static func isLocalClient(_ clientID: String?) -> Bool {
      clientID == MCPClientID.qwenStudio.rawValue || clientID == MCPClientID.gemini.rawValue
    }
  }
#endif
