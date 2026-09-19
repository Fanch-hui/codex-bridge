import BridgeAgentCore
import Foundation

extension ServiceAgentAutoDiscovery {
  static func deepSeekLauncherCandidates(
    environment: [String: String]
  ) -> [String] {
    #if os(Windows)
      let resolver = AgentExecutableResolver(environment: environment)
      let directories = uniquePaths(
        resolver.searchDirectories()
          + deepSeekPackageManagerDirectories(environment: environment)
      )
      return directories.flatMap { directory -> [String] in
        ["dsh", "dsh.cmd", "dsh.bat"].flatMap { name -> [String] in
          let launcher = pathJoin(directory, name)
          guard let canonical = canonicalRegularFile(launcher) else { return [] }
          if name == "dsh" { return [canonical] }
          return deepSeekWindowsLauncherTargets(at: launcher)
        }
      }
    #else
      let resolver = AgentExecutableResolver(
        environment: environment,
        additionalDirectories: macOSAgentSearchDirectories(environment: environment)
      )
      return resolver.searchDirectories().compactMap { directory in
        canonicalRegularFile(pathJoin(directory, "dsh"))
      }
    #endif
  }

  #if os(Windows)
    private static func deepSeekPackageManagerDirectories(
      environment: [String: String]
    ) -> [String] {
      let roots = [
        environmentValue("PNPM_HOME", environment: environment),
        environmentValue("NPM_CONFIG_PREFIX", environment: environment),
        environmentValue("YARN_GLOBAL_FOLDER", environment: environment),
        environmentValue("COREPACK_HOME", environment: environment),
        environmentValue("APPDATA", environment: environment).map {
          pathJoin($0, "pnpm")
        },
        environmentValue("LOCALAPPDATA", environment: environment).map {
          pathJoin($0, "pnpm")
        },
        environmentValue("APPDATA", environment: environment).map {
          pathJoin($0, "npm")
        },
        environmentValue("LOCALAPPDATA", environment: environment).map {
          pathJoin($0, "npm")
        },
      ].compactMap { $0 }
      return roots.flatMap { root in
        [
          root,
          pathJoin(root, "bin"),
          pathJoin(root, "global"),
          pathJoin(root, "global", "5"),
          pathJoin(root, "node_modules", ".bin"),
          pathJoin(root, "global", "5", "node_modules", ".bin"),
        ]
      }
    }

    private static func deepSeekWindowsLauncherTargets(at launcher: String) -> [String] {
      guard
        let data = try? Data(
          contentsOf: URL(fileURLWithPath: launcher),
          options: [.mappedIfSafe]
        ),
        data.count <= 128 * 1_024,
        let directory = AgentPathSemantics.directoryPath(of: launcher)
      else { return [] }
      let text = String(decoding: data, as: UTF8.self)
      return launcherTokens(text).compactMap { token in
        guard isDeepSeekEntryReference(token) else { return nil }
        return resolveLauncherToken(token, relativeTo: directory)
      }
    }

    private static func launcherTokens(_ text: String) -> [String] {
      var tokens: [String] = []
      var token = ""
      var quoted = false
      for character in text {
        if character == "\"" {
          quoted.toggle()
        } else if character.isWhitespace && !quoted {
          if !token.isEmpty {
            tokens.append(token)
            token.removeAll(keepingCapacity: true)
          }
        } else {
          token.append(character)
        }
      }
      if !token.isEmpty { tokens.append(token) }
      return tokens
    }

    private static func isDeepSeekEntryReference(_ token: String) -> Bool {
      let normalized = token.replacingOccurrences(of: "/", with: "\\").lowercased()
      return normalized.contains("\\apps\\cli\\lib\\bin.js")
        || normalized.contains("\\packages\\examples\\acp-demo\\lib\\bin.js")
        || normalized.contains("\\node_modules\\@deepseek-ai\\dsh\\lib\\bin.js")
    }

    private static func resolveLauncherToken(
      _ token: String,
      relativeTo directory: String
    ) -> String? {
      var value = token.trimmingCharacters(in: CharacterSet(charactersIn: "()'"))
      for variable in ["%~dp0", "%dp0%"] {
        value = value.replacingOccurrences(
          of: variable,
          with: pathJoin(directory, ""),
          options: [.caseInsensitive]
        )
      }
      guard !value.contains("%"), !value.contains("!") else { return nil }
      let path = AgentPathSemantics.isAbsolute(value) ? value : pathJoin(directory, value)
      return canonicalRegularFile(path)
    }
  #endif
}
