import BridgeACP
import BridgeSecurity
import Foundation

extension ProviderHostClient {
  func consume(_ data: Data) async throws {
    let message = try JSONDecoder().decode(ACPJSONValue.self, from: data)
    if message["method"]?.stringValue == "bridge/secret" {
      try receiveSecretRequest(message)
      return
    }
    guard let number = message["id"]?.intValue else {
      // Provider diagnostics are intentionally not forwarded to UI or logs with raw auth data.
      guard let event = message["event"]?.stringValue,
        ["log", "toast", "auth", "signIn"].contains(event)
      else { throw ProviderRuntimeError.invalidMessage }
      return
    }
    let id = Int64(number)
    guard let item = pending[id], !item.cancelling else { return }
    if let event = message["event"]?.stringValue {
      try receiveStream(message, id: id, event: event, item: item)
    } else if let error = message["error"] {
      let diagnostic = OutboundContentSecurity.redactedSecrets(
        error["message"]?.stringValue ?? "供应商请求失败。", maximumUTF8Bytes: 4096)
      try complete(id, item: item, result: .failure(ProviderRuntimeError.remote(diagnostic)))
    } else if let result = message["result"] {
      guard item.stream == nil || item.receivedHead else {
        throw ProviderRuntimeError.invalidMessage
      }
      try complete(id, item: item, result: .success(result))
    } else {
      throw ProviderRuntimeError.invalidMessage
    }
  }

  private func receiveStream(
    _ message: ACPJSONValue, id: Int64, event: String, item: Pending
  ) throws {
    guard let delivery = item.delivery else { throw ProviderRuntimeError.invalidMessage }
    let value: ProviderResponseEvent
    var credit = 0
    switch event {
    case "head":
      guard !item.receivedHead, let status = message["status"]?.intValue,
        (100...599).contains(status), let rawHeaders = message["headers"]?.objectValue,
        rawHeaders.count <= 256
      else { throw ProviderRuntimeError.invalidMessage }
      var headers: [String: String] = [:]
      for (name, raw) in rawHeaders {
        guard let value = raw.stringValue else { throw ProviderRuntimeError.invalidMessage }
        headers[name] = value
      }
      pending[id]?.receivedHead = true
      value = .head(status: status, headers: headers)
    case "chunk":
      guard item.receivedHead, let encoded = message["data"]?.stringValue,
        let bytes = Data(base64Encoded: encoded), bytes.count <= 65536
      else { throw ProviderRuntimeError.invalidMessage }
      value = .chunk(bytes)
      credit = bytes.count + 2048
    default:
      throw ProviderRuntimeError.invalidMessage
    }
    try delivery.enqueue(.event(value, credit: credit))
  }

  private func receiveSecretRequest(_ message: ACPJSONValue) throws {
    guard let id = message["id"]?.stringValue, id.hasPrefix("bridge-secret-"),
      callbacks[id] == nil, callbacks.count < 32, let params = message["params"]
    else { throw ProviderRuntimeError.invalidMessage }
    let handler = secretHandler
    callbacks[id] = Task { [weak self] in
      let reply: ACPJSONValue
      do {
        let result = try await handler(params)
        reply = .object(["id": .string(id), "result": result])
      } catch {
        reply = .object([
          "id": .string(id), "error": .object(["message": .string("凭据操作失败。")]),
        ])
      }
      await self?.completeSecret(id, reply: reply)
    }
  }

  private func completeSecret(_ id: String, reply: ACPJSONValue) async {
    guard callbacks.removeValue(forKey: id) != nil, !closed else { return }
    do { try await send(reply) } catch { _ = await close(error: error) }
  }
}
