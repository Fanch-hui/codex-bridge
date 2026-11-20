import BridgeACP
import BridgeAgentCore
import BridgeProviderRuntime
import Foundation

/// The helper owns only protocol state; credentials and upstream requests stay in the service.
actor ServiceModelConversion {
  let client: ProviderHostClient
  let id = UUID().uuidString

  init(resources: ProviderRuntimeResources, directory: URL) async throws {
    try resources.validateEntrypoints()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var environment: [String: String] = [:]
    #if os(Windows)
      let inherited = ProcessInfo.processInfo.environment
      AgentProviderEnvironment.applyWindowsSystemEnvironment(to: &environment, from: inherited)
      if let windir = AgentProviderEnvironment.environmentValue("WINDIR", source: inherited),
        !windir.isEmpty, !windir.contains("\0")
      {
        environment["WINDIR"] = windir
      }
      environment["TEMP"] = directory.path
      environment["TMP"] = directory.path
    #endif
    let transport = try ACPProcessTransport.launch(
      configuration: ACPProcessTransportConfiguration(
        argv: [resources.protocolExecutable.path, "--state-dir", directory.path],
        workingDirectory: directory.path, environment: environment,
        maximumFrameBytes: 32 * 1_024 * 1_024))
    client = ProviderHostClient(transport: transport) { _ in
      throw ProviderRuntimeError.invalidMessage
    }
    await client.start()
  }

  func translate(body: Data, from: String, to: String, model: String, host: String, plugin: Bool)
    async throws -> Data
  {
    let result: ACPJSONValue
    do {
      result = try await client.request(
        method: "translateRequest",
        params: .object([
          "requestId": .string(id), "from": .string(from), "to": .string(to),
          "model": .string(model), "host": .string(host), "plugin": .bool(plugin),
          "body": .string(String(decoding: body, as: UTF8.self)),
        ]))
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
    try bytes(
      await client.request(method: "finishResponse", params: .object(["requestId": .string(id)])))
  }

  func close() async throws {
    guard await client.close() else { throw ProviderRuntimeError.processTreeStillRunning }
  }

  private func bytes(_ result: ACPJSONValue) throws -> Data {
    guard let value = result["data"]?.stringValue, let data = Data(base64Encoded: value) else {
      throw ProviderRuntimeError.invalidMessage
    }
    return data
  }
}
