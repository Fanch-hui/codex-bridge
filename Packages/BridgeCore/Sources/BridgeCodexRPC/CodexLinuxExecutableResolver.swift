#if os(Linux)
  import BridgeAgentCore
  import Foundation

  enum CodexLinuxExecutableResolver {
    static func resolve(
      environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
      if let configured = environment["CODEX_BRIDGE_CODEX_EXECUTABLE"],
        let executable = resolve(configuredPath: configured)
      {
        return executable
      }
      let resolver = AgentExecutableResolver(
        environment: environment,
        additionalDirectories: LinuxAgentInstallationDirectories.search(environment: environment)
      )
      return resolver.resolve("codex").map { URL(fileURLWithPath: $0) }
    }

    static func resolve(configuredPath: String) -> URL? {
      let path = CodexExecutablePathInput.normalized(configuredPath)
      guard AgentPathSemantics.isAbsolute(path),
        let resolved = AgentExecutableResolver().resolve(path)
      else { return nil }
      return URL(fileURLWithPath: resolved)
    }
  }
#endif
