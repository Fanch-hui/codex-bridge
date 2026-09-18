#if os(Windows)
  import BridgeAgentCore
  import Foundation
  import WinSDK

  extension ServiceAgentWindowsInstallationSources {
    private static let keyReadAccess: REGSAM = 0x0002_0019
    private static let uninstallRoots = [
      #"Software\Microsoft\Windows\CurrentVersion\Uninstall"#,
      #"Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall"#,
    ]
    private static let appPathRoots = [
      #"Software\Microsoft\Windows\CurrentVersion\App Paths"#,
      #"Software\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths"#,
    ]

    static func appPathDirectories(names: [String]) -> [String] {
      let valueNames = uniqueStrings(names.flatMap { ["\($0).exe", "\($0).cmd", "\($0).bat"] })
      let roots: [HKEY?] = [HKEY_CURRENT_USER, HKEY_LOCAL_MACHINE]
      var directories: [String] = []
      for root in roots {
        for appPathRoot in appPathRoots {
          for valueName in valueNames {
            let keyPath = appPathRoot + "\\" + valueName
            if let executable = readRegistryString(root: root, keyPath: keyPath, valueName: "") {
              appendPathDirectory(executable, to: &directories)
            }
            if let searchPath = readRegistryString(root: root, keyPath: keyPath, valueName: "Path")
            {
              directories += AgentPathSemantics.splitPathList(searchPath, style: .windows)
            }
          }
        }
      }
      return directories
    }

    static func uninstallDirectories(names: [String]) -> [String] {
      let roots: [HKEY?] = [HKEY_CURRENT_USER, HKEY_LOCAL_MACHINE]
      var directories: [String] = []
      for root in roots {
        for uninstallRoot in uninstallRoots {
          guard let key = openKey(root: root, keyPath: uninstallRoot) else { continue }
          defer { RegCloseKey(key) }
          var index: DWORD = 0
          while index < 512 {
            var buffer = [WCHAR](repeating: 0, count: 512)
            var length = DWORD(buffer.count)
            let status = RegEnumKeyExW(key, index, &buffer, &length, nil, nil, nil, nil)
            if status == ERROR_NO_MORE_ITEMS { break }
            index += 1
            guard status == ERROR_SUCCESS else { continue }
            let entry = String(decoding: buffer.prefix(Int(length)), as: UTF16.self)
            let entryPath = uninstallRoot + "\\" + entry
            let displayName = readRegistryString(
              root: root, keyPath: entryPath, valueName: "DisplayName")
            guard matchesKnownName(names: names, values: [entry, displayName]) else { continue }
            let installLocation = readRegistryString(
              root: root, keyPath: entryPath, valueName: "InstallLocation")
            let displayIcon = readRegistryString(
              root: root, keyPath: entryPath, valueName: "DisplayIcon")
            let installSource = readRegistryString(
              root: root, keyPath: entryPath, valueName: "InstallSource")
            for value in [installLocation, displayIcon, installSource].compactMap({ $0 }) {
              appendPathDirectory(value, to: &directories)
            }
          }
        }
      }
      return directories
    }

    private static func matchesKnownName(names: [String], values: [String?]) -> Bool {
      let haystack = values.compactMap { $0 }.joined(separator: " ").lowercased()
      return names.contains { haystack.contains($0.lowercased()) }
    }

    private static func appendPathDirectory(_ value: String, to directories: inout [String]) {
      let token = installationPath(value)
      guard let canonical = AgentPathSemantics.canonicalPath(token),
        AgentPathSemantics.isAbsolute(canonical, style: .windows)
      else { return }
      let extensionName = URL(fileURLWithPath: canonical).pathExtension.lowercased()
      if ["exe", "com", "cmd", "bat"].contains(extensionName) {
        if let directory = AgentPathSemantics.directoryPath(of: canonical, style: .windows) {
          directories.append(directory)
        }
      } else {
        directories.append(canonical)
      }
    }

    static func installationPath(_ value: String) -> String {
      var path = value.trimmingCharacters(in: .whitespacesAndNewlines)
      if let comma = path.lastIndex(of: ","),
        Int(path[path.index(after: comma)...].trimmingCharacters(in: .whitespaces)) != nil
      {
        path = String(path[..<comma])
      }
      return path.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }

    private static func readRegistryString(
      root: HKEY?, keyPath: String, valueName: String
    ) -> String? {
      guard let key = openKey(root: root, keyPath: keyPath) else { return nil }
      defer { RegCloseKey(key) }
      var type: DWORD = 0
      var byteCount: DWORD = 0
      let measured = valueName.withCString(encodedAs: UTF16.self) { name in
        RegQueryValueExW(key, name, nil, &type, nil, &byteCount)
      }
      guard measured == ERROR_SUCCESS, byteCount > 0, byteCount <= 65_536,
        type == DWORD(REG_SZ) || type == DWORD(REG_EXPAND_SZ)
      else { return nil }
      var buffer = [WCHAR](repeating: 0, count: Int(byteCount) / MemoryLayout<WCHAR>.size + 1)
      let read = valueName.withCString(encodedAs: UTF16.self) { name in
        buffer.withUnsafeMutableBytes { bytes in
          RegQueryValueExW(
            key, name, nil, &type,
            bytes.baseAddress?.assumingMemoryBound(to: BYTE.self), &byteCount
          )
        }
      }
      guard read == ERROR_SUCCESS else { return nil }
      let value = String(decoding: buffer.prefix(while: { $0 != 0 }), as: UTF16.self)
      let resolved: String
      if type == DWORD(REG_EXPAND_SZ) {
        resolved = value.withCString(encodedAs: UTF16.self) { source in
          let count = ExpandEnvironmentStringsW(source, nil, 0)
          guard count > 0, count <= 32_768 else { return value }
          var expanded = [WCHAR](repeating: 0, count: Int(count))
          let written = ExpandEnvironmentStringsW(source, &expanded, count)
          guard written > 0, written <= count else { return value }
          return String(decoding: expanded.prefix(while: { $0 != 0 }), as: UTF16.self)
        }
      } else {
        resolved = value
      }
      return resolved.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : resolved
    }

    private static func openKey(root: HKEY?, keyPath: String) -> HKEY? {
      var key: HKEY?
      let status = keyPath.withCString(encodedAs: UTF16.self) { path in
        RegOpenKeyExW(root, path, 0, keyReadAccess, &key)
      }
      return status == ERROR_SUCCESS ? key : nil
    }
  }
#endif
