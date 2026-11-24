import BridgeACP
import BridgeModelGateway
import Foundation

/// Official Codex models keep the native Responses WebSocket: one upstream socket per client
/// socket, frames relayed unchanged so incremental turns, prewarm, compaction items and
/// server-side connection state behave as in a direct connection.
extension ServiceProviderGateway {
  static let codexWebSocketRequestHeaders =
    codexInferenceHeaders.subtracting(["accept"]).union([
      "traceparent", "tracestate", "x-oai-attestation", "x-responsesapi-include-timing-metrics",
    ])

  static let codexWebSocketResponseHeaders: Set<String> = codexResponseHeaders.subtracting([
    "cache-control", "content-type", "www-authenticate",
  ]).union([
    "x-reasoning-included", "openai-model", "x-codex-websocket-max-message-bytes", "x-models-etag",
  ])

  nonisolated func acceptCodexWebSocket(
    _ request: ModelGatewayRequest, authentication: ServiceGatewayAuthentication
  ) async -> ModelGatewayWebSocketAcceptance {
    // 426 makes Codex switch this session to HTTP immediately, where the ordinary checks reply.
    #if os(macOS)
      guard authentication.allowsCodexPassthrough(request.client),
        let auth = request.upstreamAuth, auth.hasCredential,
        let query = Self.codexVersionQuery(userAgent: request.headers["user-agent"])
      else { return .reject(status: 426) }
      let upstream: CodexUpstreamWebSocket
      do {
        upstream = try await CodexUpstreamWebSocket.connect(
          await codexWebSocketRequest(request, auth: auth), timeout: .seconds(10))
      } catch let error as CodexUpstreamWebSocket.HandshakeError {
        // URLSession hides a refused handshake's status; HTTP then reports it, e.g. 401 refresh.
        return .reject(status: error.status ?? 426)
      } catch {
        return .reject(status: 426)
      }
      let headers = upstream.responseHeaders.filter {
        Self.codexWebSocketResponseHeaders.contains($0.key)
      }
      return .accept(headers: headers) { [self] client in
        await relayCodexWebSocket(
          client: client, upstream: upstream, request: request, query: query,
          authentication: authentication)
      }
    #else
      return .reject(status: 426)
    #endif
  }

  #if os(macOS)
    private func codexWebSocketRequest(
      _ request: ModelGatewayRequest, auth: ModelGatewayUpstreamAuth
    ) -> URLRequest {
      var components = URLComponents(
        url: codexUpstreamEndpoints.responses, resolvingAgainstBaseURL: false)
      let secure = components?.scheme != "http"
      components?.scheme = secure ? "wss" : "ws"
      var outgoing = URLRequest(url: components?.url ?? codexUpstreamEndpoints.responses)
      outgoing.httpShouldHandleCookies = false
      outgoing.setValue(auth.authorization, forHTTPHeaderField: "Authorization")
      outgoing.setValue(auth.chatGPTAccountID, forHTTPHeaderField: "ChatGPT-Account-ID")
      for name in Self.codexWebSocketRequestHeaders.union(["originator", "user-agent"]) {
        outgoing.setValue(request.headers[name], forHTTPHeaderField: name)
      }
      return outgoing
    }

    private nonisolated func relayCodexWebSocket(
      client: ModelGatewayWebSocket, upstream: CodexUpstreamWebSocket,
      request: ModelGatewayRequest, query: String, authentication: ServiceGatewayAuthentication
    ) async {
      let delivered = CodexWebSocketDelivery()
      let rounds = CodexWebSocketRounds()
      await withTaskGroup(of: Void.self) { group in
        group.addTask { [self] in
          while let message = try? await upstream.receive() {
            guard (try? await client.send(message)) != nil else { break }
            delivered.mark()
            if case .text(let text) = message, let state = Self.codexWebSocketTerminalState(text),
              let round = rounds.finish()
            {
              let usage = ServiceGatewayUsage(stream: false)
              await usage.receive(Data(text.utf8))
              await recordOfficialCodex(
                request: request, model: round.model, started: round.started, state: state,
                usage: await usage.presentation())
            }
          }
          await client.close(code: upstream.closeCode ?? 1011)
        }
        group.addTask { [self] in
          for await message in client.messages {
            var outgoing = message
            if case .text(let text) = message {
              switch await routeCodexWebSocketText(
                text, request: request, query: query, authentication: authentication)
              {
              case .forward(let routed, let model):
                outgoing = .text(routed)
                if let model { rounds.begin(model: model) }
              case .gatewayModel:
                await leaveCodexWebSocket(client, delivered: delivered.value)
                return
              case .fail(let status, let code):
                _ = try? await client.send(.text(Self.codexWebSocketError(status, code)))
                await client.close(code: 1000)
                return
              }
            }
            guard (try? await upstream.send(outgoing)) != nil else { return }
          }
        }
        await group.next()
        upstream.close(code: 1000)
        await client.close(code: 1000)
      }
      if let round = rounds.finish() {
        await recordOfficialCodex(
          request: request, model: round.model, started: round.started, state: "cancelled",
          usage: .object(["status": .string("not_provided")]))
      }
    }

    /// Gateway models stay on HTTP. Closing with 1009 before any server frame switches the
    /// session to HTTP at once; later, a retryable error reconnects and replays the full turn.
    private nonisolated func leaveCodexWebSocket(
      _ client: ModelGatewayWebSocket, delivered: Bool
    ) async {
      if delivered {
        _ = try? await client.send(
          .text(Self.codexWebSocketError(400, "previous_response_not_found")))
        await client.close(code: 1000)
      } else {
        await client.close(code: 1009)
      }
    }
  #endif

  enum CodexWebSocketRoute: Equatable {
    /// `model` is set for a generating `response.create`, which opens one usage record.
    case forward(String, model: String? = nil)
    case gatewayModel
    case fail(status: Int, code: String)
  }

  /// Only `response.create` is inspected; other frames, such as interrupts, pass through.
  nonisolated func routeCodexWebSocketText(
    _ text: String, request: ModelGatewayRequest, query: String,
    authentication: ServiceGatewayAuthentication
  ) async -> CodexWebSocketRoute {
    guard
      let body = try? JSONDecoder().decode(ACPJSONValue.self, from: Data(text.utf8)).objectValue,
      body["type"]?.stringValue == "response.create"
    else { return .forward(text) }
    guard authentication.allowsCodexPassthrough(request.client) else {
      return .fail(status: 401, code: "invalid_client")
    }
    guard let model = body["model"]?.stringValue, !model.isEmpty else {
      return .fail(status: 400, code: "invalid_request")
    }
    if model.hasPrefix(ServiceCodexGatewayCatalog.slugPrefix) { return .gatewayModel }
    do {
      switch try await officialCodexModelIDs(request, query: query, authentication: authentication)
      {
      case .failed(let response): return .fail(status: response.status, code: "upstream_failed")
      case .ids(let ids) where !ids.contains(model):
        return .fail(status: 403, code: "model_not_authorized")
      case .ids: break
      }
    } catch ServiceGatewayRequestError.unauthorized {
      return .fail(status: 401, code: "invalid_client")
    } catch {
      return .fail(status: 502, code: "upstream_failed")
    }
    // Prewarm requests (`generate: false`) produce no model output and are not recorded.
    let round = body["generate"]?.boolValue == false ? nil : model
    var projected = body
    Self.projectCodexHistory(&projected, official: true)
    guard projected != body, let data = try? ACPJSONValue.object(projected).encodedData() else {
      return .forward(text, model: round)
    }
    return .forward(String(decoding: data, as: UTF8.self), model: round)
  }

  /// Escaped quotes inside string values cannot match, so only a frame's own type qualifies.
  static func codexWebSocketTerminalState(_ text: String) -> String? {
    if text.contains("\"type\":\"response.completed\"") { return "completed" }
    if text.contains("\"type\":\"response.incomplete\"") {
      return text.contains("\"reason\":\"interrupted\"") ? "cancelled" : "failed"
    }
    if text.contains("\"type\":\"response.failed\"") || text.contains("\"type\":\"error\"") {
      return "failed"
    }
    return nil
  }

  static func codexWebSocketError(_ status: Int, _ code: String) -> String {
    let payload = ACPJSONValue.object([
      "type": .string("error"), "status": .integer(Int64(status)),
      "error": .object(["code": .string(code), "message": .string(code)]),
    ])
    return (try? payload.encodedData()).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
  }
}

/// The one in-flight `response.create` on a connection; Codex never overlaps them.
final class CodexWebSocketRounds: @unchecked Sendable {
  private let lock = NSLock()
  private var current: (model: String, started: Date)?
  func begin(model: String) { lock.withLock { current = (model, Date()) } }
  func finish() -> (model: String, started: Date)? {
    lock.withLock {
      defer { current = nil }
      return current
    }
  }
}

/// Whether the client has received any server frame on this connection.
final class CodexWebSocketDelivery: @unchecked Sendable {
  private let lock = NSLock()
  private var delivered = false
  func mark() { lock.withLock { delivered = true } }
  var value: Bool { lock.withLock { delivered } }
}
