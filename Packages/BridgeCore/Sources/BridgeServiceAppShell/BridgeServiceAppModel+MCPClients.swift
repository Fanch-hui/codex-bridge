import AppKit
import BridgeMCP
import BridgeServiceAppCore
import Foundation

extension BridgeServiceAppModel {
  public func setQwenStudioEnabled(_ enabled: Bool) {
    setLocalMCPClientEnabled(.qwenStudio, enabled: enabled)
  }

  func setLocalMCPClientEnabled(_ id: MCPClientID, enabled: Bool) {
    runMutation { [weak self] client in
      guard let self else { return }
      try await client.setMCPClientEnabled(
        clientID: id.rawValue,
        enabled: enabled
      )
      await self.refresh(silent: true, includeCatalog: false)
      let name = id == .gemini ? "Gemini" : "Qwen Studio"
      self.postToast(enabled ? "已启用 \(name) 客户端" : "已停用 \(name) 客户端")
    }
  }

  public func setQwenStudioExposureMode(_ mode: MCPServiceExposureMode) {
    setLocalMCPClientExposureMode(.qwenStudio, mode: mode)
  }

  func setLocalMCPClientExposureMode(_ id: MCPClientID, mode: MCPServiceExposureMode) {
    runMutation { [weak self] client in
      guard let self else { return }
      try await client.setMCPClientExposureMode(
        clientID: id.rawValue,
        mode: mode
      )
      await self.refresh(silent: true, includeCatalog: false)
      let name = id == .gemini ? "Gemini" : "Qwen"
      self.postToast("\(name) 工具权限已设置为：\(mode.localizedTitle)")
    }
  }

  public func copyQwenStudioConfiguration() {
    runMutation { [weak self] client in
      let configuration = try await client.exportMCPClientConfiguration(
        clientID: MCPClientID.qwenStudio.rawValue
      )
      let pasteboard = NSPasteboard.general
      pasteboard.clearContents()
      pasteboard.setString(configuration, forType: .string)
      self?.postToast("已复制 Qwen Studio JSON 配置")
    }
  }

  public func rotateQwenStudioCredential() {
    rotateLocalMCPClientCredential(.qwenStudio)
  }

  func rotateLocalMCPClientCredential(_ id: MCPClientID) {
    runMutation { [weak self] client in
      guard let self else { return }
      try await client.rotateMCPClientCredential(clientID: id.rawValue)
      await self.refresh(silent: true, includeCatalog: false)
      self.postToast(id == .gemini ? "Gemini 连接已重置，请在 Gemini 中重新连接" : "已重新生成 Qwen 凭证")
    }
  }

  func copyGeminiLocalMCPCommand() {
    do {
      let command = try GeminiLocalMCPCommand.command()
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(command, forType: .string)
      postToast("已复制 Gemini 本地 MCP 启动命令")
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  public func rotateLocalMCPEndpoint() {
    runMutation { [weak self] client in
      guard let self else { return }
      _ = try await client.rotateLocalMCPEndpoint()
      await self.refresh(silent: true, includeCatalog: false)
      self.postToast("已重新生成本地 MCP Endpoint")
    }
  }
}
