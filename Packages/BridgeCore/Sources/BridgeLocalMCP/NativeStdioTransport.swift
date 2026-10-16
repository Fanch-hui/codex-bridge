import MCP

enum NativeStdioTransport {
  static func make() -> any Transport {
    #if os(Windows)
      WindowsMCPStdioTransport()
    #else
      StdioTransport()
    #endif
  }
}
