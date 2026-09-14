import BridgeIPC

extension BridgeServiceAppModel {
  public func saveDeepSeekSearchConfiguration(baseURL: String?) {
    runMutation { [weak self] client in
      let saved = try await client.saveDeepSeekSearchConfiguration(.init(baseURL: baseURL))
      self?.deepSeekSearchBaseURL = saved.baseURL
      self?.postToast("DSH 搜索配置已保存")
    }
  }
}
