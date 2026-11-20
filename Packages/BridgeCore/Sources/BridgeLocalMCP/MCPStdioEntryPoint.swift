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
  enum Invocation {
    case probe(LocalMCPProbe)
    case stdio(clientID: String)
  }

  enum InvocationError: Error {
    case invalidArguments
    case invalidProbe
  }

  static func parseInvocation(_ arguments: [String]) throws -> Invocation? {
    guard
      arguments.first == "--mcp-stdio" || arguments.first == "--mcp-stdio-probe"
        || arguments.first == "--mcp-client"
    else {
      return nil
    }
    if arguments.first == "--mcp-stdio-probe" {
      do {
        return .probe(try LocalMCPProbe(arguments: Array(arguments.dropFirst())))
      } catch {
        throw InvocationError.invalidProbe
      }
    }
    if arguments.first == "--mcp-client" {
      guard arguments.count == 2, isExternalClientID(arguments[1]) else {
        throw InvocationError.invalidArguments
      }
      return .stdio(clientID: arguments[1])
    }
    if arguments.count == 1 {
      return .stdio(clientID: "google.gemini")
    }
    if arguments.count == 3, arguments[1] == "--mcp-client", isExternalClientID(arguments[2]) {
      return .stdio(clientID: arguments[2])
    }
    throw InvocationError.invalidArguments
  }

  public static func runIfRequested() {
    let arguments = Array(CommandLine.arguments.dropFirst())
    let invocation: Invocation
    do {
      guard let parsed = try parseInvocation(arguments) else { return }
      invocation = parsed
    } catch InvocationError.invalidProbe {
      FileHandle.standardError.write(
        Data("探针参数无效。请使用准备脚本生成的 --endpoint 与 --marker-file 参数。\n".utf8))
      exit(64)
    } catch {
      exit(64)
    }
    let probe: LocalMCPProbe?
    let clientID: String
    switch invocation {
    case .probe(let parsedProbe):
      probe = parsedProbe
      clientID = "google.gemini"
    case .stdio(let parsedClientID):
      probe = nil
      clientID = parsedClientID
    }
    #if !os(Windows)
      signal(SIGPIPE, SIG_IGN)
    #endif
    Task.detached {
      if let probe {
        do {
          try await probe.serve()
          exit(0)
        } catch {
          FileHandle.standardError.write(Data("本地 MCP 沙盒探针已结束，stdio 传输失败。\n".utf8))
          exit(1)
        }
      }
      var stage = MCPStdioFailureStage.serviceConnection
      do {
        let configuration = try await localConfiguration(clientID: clientID)
        stage = .forwarding
        let connection = try LocalMCPConnection(configuration: configuration)
        let proxy = MCPStdioProxy(stdio: NativeStdioTransport.make(), connection: connection)
        try await proxy.run()
        exit(0)
      } catch {
        FileHandle.standardError.write(
          Data((stage.diagnostic(for: error, clientID: clientID) + "\n").utf8)
        )
        exit(1)
      }
    }
    dispatchMain()
  }

  static func isExternalClientID(_ value: String) -> Bool {
    guard value.hasPrefix("external.") else { return false }
    let suffix = String(value.dropFirst("external.".count))
    return UUID(uuidString: suffix)?.uuidString.lowercased() == suffix
  }

  private static func localConfiguration(clientID: String) async throws
    -> IPCLocalMCPConnectionResponse
  {
    #if os(macOS)
      if clientID == "google.gemini" {
        do {
          return try await MacLocalMCPConfiguration.load()
        } catch MacLocalMCPError.system(let code) where code == ENOENT || code == ECONNREFUSED {
          // An older service may still be running during an application upgrade.
        }
      }
    #endif
    let client = BridgeServiceClient(transport: ServiceTransportFactory.defaultTransport())
    do {
      let configuration = try await client.localMCPConnection(clientID: clientID)
      await client.invalidate()
      return configuration
    } catch {
      await client.invalidate()
      throw error
    }
  }
}

enum MCPStdioFailureStage {
  case serviceConnection
  case forwarding

  func diagnostic(for error: any Error, clientID: String = "google.gemini") -> String {
    if clientID != "google.gemini" {
      return "无法连接此应用的 Bridge MCP。请确认后台服务可用，且该应用的 MCP 接入已启用。"
    }
    if case .serviceConnection = self {
      if let codecError = error as? BridgeServiceIPCCodecError,
        case .remoteError(let remote) = codecError, remote.code == "client_disabled"
      {
        return "Gemini 本地 MCP 未启用。请打开 Codex Bridge，在「连接 → Gemini」中启用 Gemini。"
      }
      var message = "无法取得 Gemini 本地 MCP 连接配置。请打开 Codex Bridge，确认后台服务可用，并启用 Gemini。"
      #if os(macOS)
        message +=
          "更新 App 后请重启后台服务；在 Gemini 中允许本地 MCP 访问本机网络及其启动命令所属的文件。"
      #endif
      return message
    }
    return "Gemini 本地 MCP 转发失败。请确认 Bridge 后台服务与 Gemini 连接保持启用，再在客户端重新连接。"
  }
}
