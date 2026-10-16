import BridgeIPC
import Dispatch
import Foundation

#if os(Windows)
  import ucrt
#elseif os(Linux)
  import Glibc
#else
  import Darwin
#endif

public enum MCPStdioEntryPoint {
  public static func runIfRequested() {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard arguments.first == "--mcp-stdio" else { return }
    guard arguments.count == 1 else { exit(64) }
    #if !os(Windows)
      signal(SIGPIPE, SIG_IGN)
    #endif
    Task.detached {
      let client = BridgeServiceClient(transport: ServiceTransportFactory.defaultTransport())
      do {
        let configuration = try await client.localMCPConnection(clientID: "google.gemini")
        await client.invalidate()
        let connection = try LocalMCPConnection(configuration: configuration)
        let proxy = MCPStdioProxy(stdio: NativeStdioTransport.make(), connection: connection)
        try await proxy.run()
        exit(0)
      } catch {
        await client.invalidate()
        FileHandle.standardError.write(
          Data("无法连接 Gemini 本地 MCP。请打开 Codex Bridge，并在连接页启用 Gemini 本地 MCP。\n".utf8)
        )
        exit(1)
      }
    }
    dispatchMain()
  }
}
