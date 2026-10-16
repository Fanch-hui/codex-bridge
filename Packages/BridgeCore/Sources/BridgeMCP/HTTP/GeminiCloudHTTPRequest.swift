import NIOHTTP1

package enum GeminiCloudHTTPRequest {
  static let pathPrefix = "/gemini-mcp/"

  static func accessKey(from head: HTTPRequestHead) -> String? {
    guard head.uri.hasPrefix(pathPrefix),
      head.headers[canonicalForm: "Authorization"].isEmpty,
      head.headers[canonicalForm: MCPHTTPConfiguration.tunnelAuthenticationHeader].isEmpty
    else { return nil }
    let key = head.uri.dropFirst(pathPrefix.count)
    guard key.utf8.count == 64,
      key.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
    else { return nil }
    return String(key)
  }

  static func localHead(from head: HTTPRequestHead, port: Int) -> HTTPRequestHead {
    var local = head
    local.uri = "/mcp"
    local.headers.remove(name: "Origin")
    local.headers.replaceOrAdd(name: "Host", value: "127.0.0.1:\(port)")
    return local
  }
}
