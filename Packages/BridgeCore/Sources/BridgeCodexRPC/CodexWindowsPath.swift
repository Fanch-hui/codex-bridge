#if os(Windows)
  import BridgeAgentCore
  import Foundation

  enum CodexWindowsPath {
    static func environmentValue(_ name: String, in environment: [String: String]) -> String? {
      guard
        let key = environment.keys.first(where: {
          $0.caseInsensitiveCompare(name) == .orderedSame
        })
      else {
        return nil
      }
      let value = environment[key] ?? ""
      return value.isEmpty ? nil : value
    }

    static func userProfile(in environment: [String: String]) -> String? {
      if let profile = environmentValue("USERPROFILE", in: environment) {
        return profile
      }
      if let drive = environmentValue("HOMEDRIVE", in: environment),
        let path = environmentValue("HOMEPATH", in: environment)
      {
        let combined = drive + path
        if !combined.isEmpty { return combined }
      }
      if let home = environmentValue("HOME", in: environment) {
        return home
      }
      let home = FileManager.default.homeDirectoryForCurrentUser.path
      return home.isEmpty ? nil : home
    }

    static func childEnvironment(
      configured: [String: String]? = nil,
      source: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
      var result = configured ?? source
      let profile = userProfile(in: result) ?? userProfile(in: source)
      if let profile {
        setIfMissing("USERPROFILE", profile, in: &result)
        setIfMissing("HOME", profile, in: &result)
        setIfMissing("APPDATA", join(profile, "AppData", "Roaming"), in: &result)
        setIfMissing("LOCALAPPDATA", join(profile, "AppData", "Local"), in: &result)
      }
      let systemRoot =
        environmentValue("SystemRoot", in: result)
        ?? environmentValue("WINDIR", in: source)
      if let systemRoot {
        setIfMissing("SystemRoot", systemRoot, in: &result)
        if let drive = drivePrefix(of: systemRoot) {
          setIfMissing("SystemDrive", drive, in: &result)
        }
        setIfMissing("ComSpec", join(systemRoot, "System32", "cmd.exe"), in: &result)
      }
      let temporary =
        environmentValue("TEMP", in: result)
        ?? environmentValue("TMP", in: result)
        ?? FileManager.default.temporaryDirectory.path
      if !temporary.isEmpty {
        setIfMissing("TEMP", temporary, in: &result)
        setIfMissing("TMP", temporary, in: &result)
      }
      return result
    }

    static func normalize(_ path: String) -> String? {
      let value = path.replacingOccurrences(of: "/", with: "\\")
      guard !value.contains("\0"), value.rangeOfCharacter(from: .controlCharacters) == nil,
        let canonical = AgentPathSemantics.canonicalPath(value, style: .windows),
        AgentPathSemantics.isAbsolute(canonical, style: .windows)
      else {
        return nil
      }
      return canonical
    }

    static func join(_ parent: String, _ components: String...) -> String {
      var value = parent.replacingOccurrences(of: "/", with: "\\")
      for component in components {
        if !value.hasSuffix("\\") { value.append("\\") }
        value.append(component.replacingOccurrences(of: "/", with: "\\"))
      }
      return value
    }

    static func parent(_ path: String) -> String? {
      guard let normalized = normalize(path), let index = normalized.lastIndex(of: "\\") else {
        return nil
      }
      let prefix = String(normalized[..<index])
      if prefix.count == 2, prefix.last == ":" { return prefix + "\\" }
      return prefix.isEmpty ? nil : prefix
    }

    static func basename(_ path: String) -> String? {
      guard let normalized = normalize(path), let index = normalized.lastIndex(of: "\\") else {
        return nil
      }
      return String(normalized[normalized.index(after: index)...])
    }

    static func splitSearchPath(_ value: String) -> [String] {
      var result: [String] = []
      var component = ""
      var quoted = false
      for character in value {
        if character == "\"" {
          quoted.toggle()
        } else if character == ";", !quoted {
          appendSearchPathComponent(&result, component)
          component.removeAll(keepingCapacity: true)
        } else {
          component.append(character)
        }
      }
      guard !quoted else { return [] }
      appendSearchPathComponent(&result, component)
      return result
    }

    static func isContained(_ path: String, in root: String) -> Bool {
      guard let path = normalize(path), let root = normalize(root) else { return false }
      return AgentPathSemantics.isContained(path, in: root, style: .windows)
    }

    static func equivalent(_ lhs: String, _ rhs: String) -> Bool {
      isContained(lhs, in: rhs) && isContained(rhs, in: lhs)
    }

    static func unique(_ values: [String]) -> [String] {
      var seen = Set<String>()
      return values.compactMap { value in
        guard let normalized = normalize(value), seen.insert(normalized.lowercased()).inserted
        else {
          return nil
        }
        return normalized
      }
    }

    private static func appendSearchPathComponent(_ result: inout [String], _ value: String) {
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty, let normalized = normalize(trimmed) else { return }
      result.append(normalized)
    }

    private static func setIfMissing(
      _ name: String,
      _ value: String,
      in environment: inout [String: String]
    ) {
      guard environmentValue(name, in: environment) == nil else { return }
      environment[name] = value
    }

    private static func drivePrefix(of path: String) -> String? {
      let characters = Array(path)
      guard characters.count >= 2, characters[1] == ":" else { return nil }
      return String(characters.prefix(2))
    }
  }
#endif
