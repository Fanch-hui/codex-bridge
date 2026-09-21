import BridgeAgentCore
import Foundation

struct DirectBuiltInCommandResolver: Sendable {
  static let trustedSystemDirectories = [
    "/usr/bin", "/bin", "/usr/sbin", "/sbin",
  ]

  static func trustedDirectories(for executable: String) -> [String] {
    guard ["node", "npm", "rg"].contains(executable) else { return trustedSystemDirectories }
    return trustedSystemDirectories + ["/opt/homebrew/bin", "/usr/local/bin"]
  }

  let rules: [DirectCommandPolicy.DirectSafeCommandRule]

  var effectiveRules: [DirectCommandPolicy.DirectSafeCommandRule] {
    #if os(Windows)
      rules.filter { rule in
        !rule.executable.contains("/") && !rule.executable.contains("\\")
          && Self.isWindowsSafeRule(rule)
          && systemExecutable(for: [rule.executable] + rule.argumentsPrefix) != nil
      }
    #else
      rules.filter { rule in
        !rule.executable.hasPrefix("/")
          && systemExecutable(for: [rule.executable] + rule.argumentsPrefix) != nil
      }
    #endif
  }

  func systemExecutable(for argv: [String]) -> String? {
    guard let executable = argv.first, !executable.isEmpty, !containsPathSeparator(executable)
    else {
      return nil
    }
    #if os(Windows)
      guard executable.caseInsensitiveCompare("find") != .orderedSame else { return nil }
    #endif
    let arguments = Array(argv.dropFirst())
    guard
      let matchedRule = rules.first(where: {
        $0.executable == executable && arguments.starts(with: $0.argumentsPrefix)
      })
    else { return nil }

    #if os(Windows)
      guard Self.isWindowsSafeRule(matchedRule) else { return nil }
      return AgentExecutableResolver(
        includeEnvironmentPath: true,
        includeUserDirectories: false,
        preferredExtensions: [".EXE"]
      ).resolve(matchedRule.executable)
    #else
      for candidate in candidates(for: matchedRule) {
        if FileManager.default.isExecutableFile(atPath: candidate) {
          return candidate
        }
      }
      return nil
    #endif
  }

  #if os(Windows)
    static func isWindowsSafeRule(_ rule: DirectCommandPolicy.DirectSafeCommandRule) -> Bool {
      let exe = rule.executable.lowercased()
      if ["echo", "pwd", "ls", "grep", "find", "xcodebuild"].contains(exe) {
        return false
      }
      if (exe == "npm" || exe == "swift")
        && (rule.argumentsPrefix.contains("test") || rule.argumentsPrefix.contains("build"))
      {
        return false
      }
      if exe == "git" {
        let safeSubcommands = [
          "status", "diff", "log", "show", "branch", "tag", "describe", "rev-parse", "ls-files",
          "--version",
        ]
        return rule.argumentsPrefix.first.map { safeSubcommands.contains($0) } ?? false
      }
      if exe == "node" {
        return [["--version"], ["--check"]].contains(rule.argumentsPrefix)
      }
      if ["npm", "swift"].contains(exe) {
        return rule.argumentsPrefix == ["--version"]
      }
      if exe == "rg" {
        return rule.argumentsPrefix.isEmpty || rule.argumentsPrefix == ["--version"]
      }
      return false
    }

    func isTrustedSystemExecutable(_ path: String, named name: String) -> Bool {
      guard
        let resolved = AgentExecutableResolver(
          includeEnvironmentPath: true,
          includeUserDirectories: false,
          preferredExtensions: [".EXE"]
        ).resolve(name)
      else { return false }
      return name.caseInsensitiveCompare("find") != .orderedSame
        && resolved.caseInsensitiveCompare(path) == .orderedSame
    }
  #endif

  private func candidates(
    for rule: DirectCommandPolicy.DirectSafeCommandRule
  ) -> [String] {
    var seen = Set<String>()
    let trustedDirectories = Self.trustedDirectories(for: rule.executable)
    let declared = rules.compactMap { candidate -> String? in
      let url = URL(fileURLWithPath: candidate.executable).standardizedFileURL
      guard candidate.executable.hasPrefix("/"),
        candidate.argumentsPrefix == rule.argumentsPrefix,
        url.lastPathComponent == rule.executable,
        trustedDirectories.contains(url.deletingLastPathComponent().path)
      else { return nil }
      return url.path
    }
    let conventional = trustedDirectories.map {
      URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent(rule.executable).path
    }
    return (conventional + declared).filter { seen.insert($0).inserted }
  }

  private func containsPathSeparator(_ value: String) -> Bool {
    value.contains("/") || value.contains("\\")
  }
}
