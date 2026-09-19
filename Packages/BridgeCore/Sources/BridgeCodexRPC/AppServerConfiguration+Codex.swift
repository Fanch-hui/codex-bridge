@preconcurrency import Foundation

extension AppServerConfiguration {
  public static func codex(executableURL: URL? = nil) -> AppServerConfiguration {
    #if os(Windows)
      if let executableURL {
        if let discovered = CodexExecutableResolver().resolve(explicitPath: executableURL.path) {
          return AppServerConfiguration(
            executableURL: URL(fileURLWithPath: discovered),
            arguments: ["app-server", "--stdio"],
            environment: CodexWindowsPath.childEnvironment()
          )
        }
        if let cmdScript = resolveCommandScript(executableURL.path) {
          return cmdScriptLaunchConfiguration(scriptPath: cmdScript)
        }
        return unavailableWindowsCodexConfiguration(
          reason:
            "The configured Codex app-server executable is unavailable or not a native Windows binary."
        )
      }
      if let discovered = CodexExecutableResolver().resolve() {
        return AppServerConfiguration(
          executableURL: URL(fileURLWithPath: discovered),
          arguments: ["app-server", "--stdio"],
          environment: CodexWindowsPath.childEnvironment()
        )
      }
      if let cmdScript = defaultWindowsCodexCommandPath() {
        return cmdScriptLaunchConfiguration(scriptPath: cmdScript)
      }
      return defaultWindowsCodexFallbackConfiguration()
    #else
      if let executableURL {
        return AppServerConfiguration(
          executableURL: executableURL,
          arguments: ["app-server", "--stdio"]
        )
      }
      if let discovered = defaultCodexExecutableURL() {
        return AppServerConfiguration(
          executableURL: discovered,
          arguments: ["app-server", "--stdio"]
        )
      }
      return AppServerConfiguration(
        executableURL: URL(fileURLWithPath: "/usr/bin/env"),
        arguments: ["codex", "app-server", "--stdio"]
      )
    #endif
  }

  #if os(Windows)
    private static func resolveCommandScript(_ path: String) -> String? {
      let normalized = CodexWindowsPath.normalize(path) ?? path
      let lower = normalized.lowercased()
      guard lower.hasSuffix(".cmd") || lower.hasSuffix(".bat") else { return nil }
      guard FileManager.default.fileExists(atPath: normalized) else { return nil }
      return normalized
    }

    private static func defaultWindowsCodexCommandPath() -> String? {
      let env = ProcessInfo.processInfo.environment
      var candidates: [String] = []
      if let appData = CodexWindowsPath.environmentValue("APPDATA", in: env) {
        candidates.append(CodexWindowsPath.join(appData, "npm", "codex.cmd"))
        candidates.append(CodexWindowsPath.join(appData, "npm", "codex.bat"))
      }
      if let localAppData = CodexWindowsPath.environmentValue("LOCALAPPDATA", in: env) {
        candidates.append(CodexWindowsPath.join(localAppData, "pnpm", "codex.cmd"))
        candidates.append(CodexWindowsPath.join(localAppData, "pnpm", "codex.bat"))
      }
      if let userProfile = CodexWindowsPath.environmentValue("USERPROFILE", in: env) {
        candidates.append(CodexWindowsPath.join(userProfile, ".bun", "bin", "codex.cmd"))
        candidates.append(CodexWindowsPath.join(userProfile, ".bun", "bin", "codex.bat"))
        candidates.append(CodexWindowsPath.join(userProfile, ".cargo", "bin", "codex.cmd"))
      }
      if let path = CodexWindowsPath.environmentValue("PATH", in: env) {
        for dir in CodexWindowsPath.splitSearchPath(path) {
          candidates.append(CodexWindowsPath.join(dir, "codex.cmd"))
          candidates.append(CodexWindowsPath.join(dir, "codex.bat"))
        }
      }
      return candidates.first(where: { FileManager.default.fileExists(atPath: $0) })
    }

    private static func cmdScriptLaunchConfiguration(scriptPath: String) -> AppServerConfiguration {
      let comSpec =
        ProcessInfo.processInfo.environment["ComSpec"] ?? "C:\\Windows\\System32\\cmd.exe"
      return AppServerConfiguration(
        executableURL: URL(fileURLWithPath: comSpec),
        arguments: ["/d", "/s", "/c", scriptPath, "app-server", "--stdio"],
        environment: CodexWindowsPath.childEnvironment()
      )
    }

    private static func defaultWindowsCodexFallbackConfiguration() -> AppServerConfiguration {
      let comSpec =
        ProcessInfo.processInfo.environment["ComSpec"] ?? "C:\\Windows\\System32\\cmd.exe"
      return AppServerConfiguration(
        executableURL: URL(fileURLWithPath: comSpec),
        arguments: ["/d", "/s", "/c", "codex", "app-server", "--stdio"],
        environment: CodexWindowsPath.childEnvironment()
      )
    }

    private static func unavailableWindowsCodexConfiguration(reason: String)
      -> AppServerConfiguration
    {
      AppServerConfiguration(
        executableURL: URL(fileURLWithPath: "C:\\CodexBridge\\Unavailable\\codex.exe"),
        arguments: ["app-server", "--stdio"],
        currentDirectoryURL: nil,
        environment: nil,
        maximumProtocolLineBytes: 64 * 1024 * 1024,
        stderrBufferBytes: 64 * 1024,
        launchFailureReason: reason
      )
    }
  #endif

  public static func defaultCodexExecutableURL() -> URL? {
    #if os(Windows)
      if let path = CodexExecutableResolver().resolve() {
        return URL(fileURLWithPath: path)
      }
      if let cmd = defaultWindowsCodexCommandPath() {
        return URL(fileURLWithPath: cmd)
      }
      return nil
    #else
      return CodexMacExecutableResolver.resolve()
    #endif
  }
}
