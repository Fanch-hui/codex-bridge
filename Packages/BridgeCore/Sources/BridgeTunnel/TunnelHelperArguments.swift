import Foundation

enum TunnelHelperArguments {
  static func make(
    command: String,
    configuration: TunnelConfiguration,
    runtimeDirectory: URL,
    healthURLFile: URL
  ) -> [String] {
    #if os(Windows)
      let apiKeyReference = "env:\(WindowsTunnelEnvironment.runtimeKeyVariable)"
      let headerSecretReference = "env:\(WindowsTunnelEnvironment.headerSecretVariable)"
    #else
      let apiKeyReference = "file:/dev/fd/3"
      let headerSecretReference = "file:/dev/fd/4"
    #endif
    var arguments = [
      command,
      "--control-plane.tunnel-id", configuration.tunnelID.rawValue,
      "--control-plane.api-key=\(apiKeyReference)",
      "--mcp.server-url", configuration.helperMCPURL.absoluteString,
      "--mcp.extra-headers", "X-Codex-Bridge-Token: \(headerSecretReference)",
      "--harpoon.allow-plaintext-http=true",
      "--health.listen-addr", "127.0.0.1:0",
      "--health.url-file", healthURLFile.path,
      "--pid.file", runtimeDirectory.appendingPathComponent("tunnel.pid").path,
      "--allow-remote-ui=false",
      "--open-web-ui=false",
      "--log.level", "warn",
      "--log.format", "json",
    ]
    if let httpProxy = configuration.httpProxy {
      arguments += ["--control-plane.http-proxy", httpProxy.url.absoluteString]
    }
    return arguments
  }
}
