import BridgeAgentCore
@preconcurrency import Foundation

extension AppServerConfiguration {
  /// Resolves the Codex app-server launch configuration.
  ///
  /// A configured path is strict: when the user pointed Bridge at a specific
  /// executable, a resolution failure must stay visible instead of silently
  /// falling back to another installation.
  public static func codex(configuredPath: String? = nil) -> AppServerConfiguration {
    #if os(Windows)
      if let configuredPath, let resolved = resolveConfiguredCodexExecutable(configuredPath) {
        if let commandScript = commandScriptPath(resolved) {
          return cmdScriptLaunchConfiguration(scriptPath: commandScript)
        }
        return AppServerConfiguration(
          executableURL: URL(fileURLWithPath: resolved),
          arguments: ["app-server", "--stdio"],
          environment: CodexWindowsPath.childEnvironment()
        )
      }
      if let configuredPath, !configuredPath.isEmpty {
        return unavailableWindowsCodexConfiguration(
          reason:
            "The configured Codex executable is unavailable or not a native Windows binary; update or clear it in the Codex connection card."
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
      if let configuredPath, !configuredPath.isEmpty {
        guard let resolved = resolveConfiguredCodexExecutable(configuredPath) else {
          return unavailableCodexConfiguration(
            reason:
              "The configured Codex executable is unavailable or not executable; update or clear it in the Codex connection card."
          )
        }
        return AppServerConfiguration(
          executableURL: URL(fileURLWithPath: resolved),
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

  /// Resolves a user-configured executable path to the program Bridge would
  /// launch, or nil when the path cannot be used.
  public static func resolveConfiguredCodexExecutable(_ configuredPath: String) -> String? {
    let trimmed = configuredPath.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    #if os(Windows)
      let resolver = CodexExecutableResolver()
      if let resolved = resolver.resolve(explicitPath: trimmed) { return resolved }
      guard let normalized = CodexWindowsPath.normalize(trimmed),
        normalized.lowercased().hasSuffix(".cmd") || normalized.lowercased().hasSuffix(".bat"),
        CodexWindowsNativeExecutable.isRegularFile(at: normalized)
      else {
        return nil
      }
      return normalized
    #else
      return CodexMacExecutableResolver.resolve(configuredPath: trimmed)?.path
    #endif
  }

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

  #if os(Windows)
    private static func commandScriptPath(_ path: String) -> String? {
      let lower = path.lowercased()
      guard lower.hasSuffix(".cmd") || lower.hasSuffix(".bat") else { return nil }
      return path
    }

    private static func defaultWindowsCodexCommandPath() -> String? {
      let env = ToolDiscoveryEnvironment.current()
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
      unavailableCodexConfiguration(reason: reason)
    }
  #endif

  private static func unavailableCodexConfiguration(reason: String) -> AppServerConfiguration {
    #if os(Windows)
      let sentinelPath = "C:\\CodexBridge\\Unavailable\\codex.exe"
    #else
      let sentinelPath = "/CodexBridge/Unavailable/codex"
    #endif
    return AppServerConfiguration(
      executableURL: URL(fileURLWithPath: sentinelPath),
      arguments: ["app-server", "--stdio"],
      currentDirectoryURL: nil,
      environment: nil,
      maximumProtocolLineBytes: 64 * 1024 * 1024,
      stderrBufferBytes: 64 * 1024,
      launchFailureReason: reason
    )
  }
}
