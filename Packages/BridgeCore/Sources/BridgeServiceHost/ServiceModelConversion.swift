import BridgeACP
import BridgeProviderRuntime
import Foundation

/// One request's use of the shared protocol helper. The helper owns only protocol state keyed by
/// this request's ID; credentials and upstream requests stay in the service.
actor ServiceModelConversion {
  private let client: ProviderHostClient
  private let owner: ServiceModelConversionHost
  private let id = UUID().uuidString
  private var finished = false
  private var released = false

  init(client: ProviderHostClient, owner: ServiceModelConversionHost) {
    self.client = client
    self.owner = owner
  }

  func translate(
    body: Data, from: String, to: String, model: String, host: String, plugin: Bool,
    reasoningScope: String?
  ) async throws -> Data {
    var params: [String: ACPJSONValue] = [
      "requestId": .string(id), "from": .string(from), "to": .string(to),
      "model": .string(model), "host": .string(host), "plugin": .bool(plugin),
      "body": .string(String(decoding: body, as: UTF8.self)),
    ]
    if let reasoningScope { params["reasoningScope"] = .string(reasoningScope) }
    let result: ACPJSONValue
    do {
      result = try await client.request(method: "translateRequest", params: .object(params))
    } catch ProviderRuntimeError.remote(let message) {
      throw ServiceGatewayRequestError.unsupported(message)
    }
    guard let body = result["body"]?.stringValue else { throw ProviderRuntimeError.invalidMessage }
    _ = try await client.request(
      method: "startResponse", params: .object(["requestId": .string(id)]))
    return Data(body.utf8)
  }

  func chunk(_ data: Data) async throws -> Data {
    let result = try await client.request(
      method: "responseChunk",
      params: .object([
        "requestId": .string(id), "data": .string(data.base64EncodedString()),
      ]))
    guard result["failed"]?.boolValue != true else {
      throw ProviderRuntimeError.remote("上游模型流返回失败。")
    }
    return try bytes(result)
  }

  func finish() async throws -> Data {
    let data = try bytes(
      await client.request(method: "finishResponse", params: .object(["requestId": .string(id)])))
    // The helper drops a request's state once it has produced the final bytes.
    finished = true
    return data
  }

  /// Ends this request's use of the helper. Unfinished state is cancelled; a helper that cannot
  /// confirm the cancel is replaced rather than left holding the request. Safe to call repeatedly.
  func release() async {
    guard !released else { return }
    released = true
    var healthy = true
    if !finished {
      let client = client
      let id = id
      // Detached so the cancel still goes out when the request's own task was cancelled.
      healthy = await Task.detached {
        do {
          _ = try await client.request(
            method: "cancel", params: .object(["requestId": .string(id)]), timeout: .seconds(5))
          return true
        } catch {
          return false
        }
      }.value
    }
    await owner.end(client, healthy: healthy)
  }

  private func bytes(_ result: ACPJSONValue) throws -> Data {
    guard let value = result["data"]?.stringValue, let data = Data(base64Encoded: value) else {
      throw ProviderRuntimeError.invalidMessage
    }
    return data
  }
}
