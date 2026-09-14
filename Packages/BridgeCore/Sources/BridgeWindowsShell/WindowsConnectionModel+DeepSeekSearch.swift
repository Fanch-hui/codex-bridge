#if os(Windows)
  import BridgeIPC
  extension WindowsConnectionModel {
    func saveDeepSeekSearchConfiguration(baseURL: String?) async {
      await mutate("正在保存 DSH 搜索配置…", success: "DSH 搜索配置已保存。") {
        let saved = try await self.client.saveDeepSeekSearchConfiguration(.init(baseURL: baseURL))
        self.deepSeekSearchBaseURL = saved.baseURL
      }
    }
  }
#endif
