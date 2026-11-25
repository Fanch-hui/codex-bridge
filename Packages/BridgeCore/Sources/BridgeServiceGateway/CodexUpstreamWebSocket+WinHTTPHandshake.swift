#if os(Windows)
  import BridgeWinHTTP
  import Foundation
  import FoundationNetworking
  import WinSDK

  /// Blocking `WinHttpOpen` … `WinHttpWebSocketCompleteUpgrade` sequence, always invoked
  /// from `operationQueue` so Swift concurrency threads never block on it.
  extension CodexUpstreamWebSocket {

    /// Fills `session`/`connection`/`request`/`socket` and `responseHeaders`, then starts
    /// the receive thread. Throws `HandshakeError` whose `status` is the HTTP answer
    /// when one came back, or nil for a network/TLS failure.
    func performHandshake(_ request: URLRequest) throws {
      guard let url = request.url else { throw HandshakeError(status: nil) }
      let secure = url.scheme == "wss" || url.scheme == "https"
      let port = UInt16(url.port ?? (secure ? 443 : 80))
      let path = (url.path.isEmpty ? "/" : url.path) + (url.query.map { "?\($0)" } ?? "")
      // WinHTTP sends the session agent as User-Agent, so Codex's own value goes there
      // instead of being added a second time as a request header.
      var fields = request.allHTTPHeaderFields ?? [:]
      let agentKey = fields.keys.first { $0.caseInsensitiveCompare("user-agent") == .orderedSame }
      let agent = agentKey.flatMap { fields.removeValue(forKey: $0) }
      let additionalHeaders = try Self.validateHeaders(fields)
      if let agent, agent.contains(where: \.isNewline) { throw HandshakeError(status: nil) }

      try adopt(
        Self.openSession(agent: agent), step: "WinHttpOpen", into: \.session)

      try adopt(
        withWString(url.host ?? "") { host in
          WinHttpConnect(core.session, host, port, 0)
        }, step: "WinHttpConnect", into: \.connection)

      let requestFlags: DWORD = secure ? DWORD(WINHTTP_FLAG_SECURE) : 0
      // Use the adopted value: `releaseHandles` may clear `core.request` at any
      // moment, so reading the slot back here could observe nil.
      let requestHandle = try adopt(
        withWString(request.httpMethod ?? "GET") { verb in
          withWString(path) { object in
            WinHttpOpenRequest(core.connection, verb, object, nil, nil, nil, requestFlags)
          }
        }, step: "WinHttpOpenRequest", into: \.request)
      try configure(requestHandle)
      // An open socket idles between turns; `connect` bounds the handshake itself.
      guard WinHttpSetTimeouts(requestHandle, 0, 60_000, 30_000, 0) else {
        throw WinHTTPError(code: GetLastError(), step: "WinHttpSetTimeouts")
      }

      let sent = withWString(additionalHeaders ?? "") { headers in
        WinHttpSendRequest(
          requestHandle,
          additionalHeaders == nil ? nil : headers,
          additionalHeaders == nil ? 0 : DWORD(bitPattern: -1), nil, 0, 0, 0)
      }
      guard sent else {
        throw WinHTTPError(code: GetLastError(), step: "WinHttpSendRequest")
      }
      guard WinHttpReceiveResponse(requestHandle, nil) else {
        throw WinHTTPError(code: GetLastError(), step: "WinHttpReceiveResponse")
      }

      let status = queryStatus(requestHandle)
      guard status == 101 else { throw HandshakeError(status: status) }
      responseHeaders = Self.parseRawHeaders(queryRawHeaders(requestHandle))

      let upgraded = WinHttpWebSocketCompleteUpgrade(requestHandle, 0)
      // A concurrent close may already own the request handle; close it only once.
      let ownsRequest = core.lock.withLock { () -> Bool in
        guard core.request == requestHandle else { return false }
        core.request = nil
        return true
      }
      if ownsRequest { WinHttpCloseHandle(requestHandle) }
      try adopt(upgraded, step: "CompleteUpgrade", into: \.socket)
      startReceiving()
    }

    /// Stores a just-opened handle: a cancelled handshake already ran
    /// `releaseHandles`, which then never revisits handles it had not seen, so a
    /// handle stored after that would leak. Assignment runs under `core.lock` so it
    /// cannot race `releaseHandles`; a `nil` handle still reports the API error.
    @discardableResult
    private func adopt(
      _ handle: HINTERNET?, step: String, into slot: ReferenceWritableKeyPath<Core, HINTERNET?>
    ) throws -> HINTERNET {
      guard let handle else { throw WinHTTPError(code: GetLastError(), step: step) }
      try core.lock.withLock {
        if core.closed {
          WinHttpCloseHandle(handle)
          throw HandshakeError(status: nil)
        }
        core[keyPath: slot] = handle
      }
      return handle
    }

    /// A session with the system proxy; a nil agent sends no User-Agent at all.
    private static func openSession(agent: String?) -> HINTERNET? {
      guard let agent else {
        return WinHttpOpen(nil, DWORD(WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY), nil, nil, 0)
      }
      return (Array(agent.utf16) + [0]).withUnsafeBufferPointer { buffer in
        WinHttpOpen(buffer.baseAddress, DWORD(WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY), nil, nil, 0)
      }
    }

    /// Options before `WinHttpSendRequest`: upgrade, no redirects, no cookies, no
    /// automatic Windows logon credentials.
    private func configure(_ request: HINTERNET) throws {
      var error = BridgeWinHTTPUpgradeToWebSocket(request)
      guard error == NO_ERROR else {
        throw WinHTTPError(code: error, step: "SetUpgrade")
      }
      error = BridgeWinHTTPApplyRequestOptions(request)
      guard error == NO_ERROR else {
        throw WinHTTPError(code: error, step: "SetOptions")
      }
    }

    /// Calls `body` with a null-terminated UTF-16 `LPCWSTR` for the string.
    func withWString<R>(_ string: String, _ body: (UnsafePointer<UInt16>) throws -> R)
      rethrows -> R
    {
      try (Array(string.utf16) + [0]).withUnsafeBufferPointer { buffer in
        try body(buffer.baseAddress!)
      }
    }

    /// Joined `Name: value` lines for `WinHttpSendRequest`; CR/LF is rejected so a
    /// caller-supplied header cannot inject extra lines.
    static func validateHeaders(_ headers: [String: String]) throws -> String? {
      var lines: [String] = []
      for (name, value) in headers {
        if name.contains(where: \.isNewline) || value.contains(where: \.isNewline) {
          throw HandshakeError(status: nil)
        }
        lines.append("\(name): \(value)")
      }
      return lines.isEmpty ? nil : lines.joined(separator: "\r\n")
    }

    /// `WINHTTP_QUERY_STATUS_CODE` as a number, or 0 when it could not be read.
    private func queryStatus(_ request: HINTERNET) -> Int {
      var status: DWORD = 0
      var length = DWORD(MemoryLayout<DWORD>.size)
      let ok = WinHttpQueryHeaders(
        request, DWORD(WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER),
        nil, &status, &length, nil)
      return ok ? Int(status) : 0
    }

    /// The raw response header block for `responseHeaders`.
    private func queryRawHeaders(_ request: HINTERNET) -> String {
      var length: DWORD = 0
      _ = WinHttpQueryHeaders(
        request, DWORD(WINHTTP_QUERY_RAW_HEADERS_CRLF), nil, nil, &length, nil)
      guard length > 0 else { return "" }
      var buffer = [UInt16](repeating: 0, count: Int(length) / 2 + 1)
      let ok = WinHttpQueryHeaders(
        request, DWORD(WINHTTP_QUERY_RAW_HEADERS_CRLF),
        nil, &buffer, &length, nil)
      guard ok else { return "" }
      return String(decoding: buffer, as: UTF16.self)
    }

    /// `Name: value` lines after the status line, keyed lowercased.
    static func parseRawHeaders(_ raw: String) -> [String: String] {
      var headers: [String: String] = [:]
      for line in raw.components(separatedBy: "\r\n").dropFirst() {
        guard let colon = line.firstIndex(of: ":") else { continue }
        let name = line[..<colon].trimmingCharacters(in: .whitespaces)
        let value = line[line.index(after: colon)...]
          .trimmingCharacters(in: .whitespaces)
        if !name.isEmpty { headers[name.lowercased()] = value }
      }
      return headers
    }
  }
#endif
