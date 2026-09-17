import BridgeAgentCore
import Foundation

struct DirectBuiltInCommandResolver: Sendable {
  private static let trustedSystemDirectories = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]

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
          "status", "diff", "log", "show", "branch", "rev-parse", "ls-files", "--version",
        ]
        return rule.argumentsPrefix.first.map { safeSubcommands.contains($0) } ?? false
      }
      if ["node", "npm"].contains(exe) {
        return rule.argumentsPrefix == ["--version"]
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
    let declared = rules.compactMap { candidate -> String? in
      let url = URL(fileURLWithPath: candidate.executable).standardizedFileURL
      guard candidate.executable.hasPrefix("/"),
        candidate.argumentsPrefix == rule.argumentsPrefix,
        url.lastPathComponent == rule.executable,
        Self.trustedSystemDirectories.contains(url.deletingLastPathComponent().path)
      else { return nil }
      return url.path
    }
    let conventional = Self.trustedSystemDirectories.map {
      URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent(rule.executable).path
    }
    return (declared + conventional).filter { seen.insert($0).inserted }
  }

  private func containsPathSeparator(_ value: String) -> Bool {
    value.contains("/") || value.contains("\\")
  }
}
