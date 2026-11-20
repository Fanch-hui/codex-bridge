import BridgeModelGateway
import BridgeProviderRuntime
import Foundation

extension ServiceProviderGateway {
  func forwardCommunity(
    model: ServiceGatewayModel, body: Data, headers: [String: String],
    response: ServiceGatewayOutput,
    usage: ServiceGatewayUsage, timeout: Duration
  ) async throws -> Bool {
    guard let communityProviders else { throw ProviderRuntimeError.closed }
    try await communityProviders.fetch(model: model, body: body, headers: headers, timeout: timeout)
    { event in
      switch event {
      case .head(let status, let headers):
        await response.prepare(status: status, headers: headers)
      case .chunk(let bytes):
        if await response.success { await usage.receive(bytes) }
        try await response.receive(bytes)
      }
    }
    if !(await response.success) { try await response.finish() }
    return await response.success
  }
}

/// Delay HTTP headers until conversion produces its first client-visible bytes. A failed conversion
/// can then return an error status even after the upstream sent 200.
actor ServiceGatewayOutput {
  let sink: ModelGatewayResponseSink
  let conversion: ServiceModelConversion?
  let stream: Bool
  let compatibilityWarnings: [String]
  var status = 200
  var headers: [String: String] = [:]
  var started = false
  var success: Bool { (200..<300).contains(status) }

  init(
    sink: ModelGatewayResponseSink, conversion: ServiceModelConversion?, stream: Bool,
    compatibilityWarnings: [String] = []
  ) {
    self.sink = sink
    self.conversion = conversion
    self.stream = stream
    self.compatibilityWarnings = compatibilityWarnings
  }

  func prepare(status: Int, headers source: [String: String]) {
    self.status = status
    let format = stream && success ? "text/event-stream" : "application/json"
    headers = [
      "content-type": conversion != nil && success ? format : (source["content-type"] ?? format),
      "cache-control": "no-cache",
    ]
    if let retry = source["retry-after"] { headers["retry-after"] = retry }
    var warnings = compatibilityWarnings.map { "299 CodexBridge \"\($0)\"" }
    if let warning = source["warning"] { warnings.append(warning) }
    if !warnings.isEmpty { headers["warning"] = warnings.joined(separator: ", ") }
  }

  func receive(_ data: Data) async throws {
    let bytes: Data
    if success, let conversion { bytes = try await conversion.chunk(data) } else { bytes = data }
    if !bytes.isEmpty { try await write(bytes) }
  }

  func finish() async throws {
    if success, let conversion {
      try await write(conversion.finish())
    } else if !started {
      try await write(Data())
    }
  }

  private func write(_ bytes: Data) async throws {
    if !started {
      try await sink.sendHead(status: status, headers: headers)
      started = true
    }
    var offset = 0
    while offset < bytes.count {
      let end = min(offset + 64 * 1024, bytes.count)
      try await sink.send(bytes.subdata(in: offset..<end))
      offset = end
    }
  }
}
