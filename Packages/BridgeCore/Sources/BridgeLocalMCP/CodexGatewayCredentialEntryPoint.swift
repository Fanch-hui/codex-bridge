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

public enum CodexGatewayCredentialEntryPoint {
  enum InvocationError: Error {
    case invalidArguments
  }

  static func clientID(from arguments: [String]) throws -> String? {
    guard arguments.first == "--export-codex-gateway-token" else { return nil }
    guard arguments.count == 2, MCPStdioEntryPoint.isExternalClientID(arguments[1]) else {
      throw InvocationError.invalidArguments
    }
    return arguments[1]
  }

  public static func runIfRequested() {
    let clientID: String
    do {
      guard let requested = try Self.clientID(from: Array(CommandLine.arguments.dropFirst())) else {
        return
      }
      clientID = requested
    } catch {
      exit(64)
    }
    Task.detached {
      let client = BridgeServiceClient(transport: ServiceTransportFactory.defaultTransport())
      do {
        let credential = try await client.codexGatewayCredential(clientID: clientID)
        await client.invalidate()
        FileHandle.standardOutput.write(Data((credential + "\n").utf8))
        exit(0)
      } catch {
        await client.invalidate()
        FileHandle.standardError.write(
          Data("无法取得 Codex 网关凭据，请确认 Bridge 后台服务和应用授权已启用。\n".utf8))
        exit(1)
      }
    }
    dispatchMain()
  }
}
