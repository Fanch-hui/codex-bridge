import Foundation

#if os(Windows)
  import WinSDK
#endif

/// Environment snapshot used when discovering locally installed tools.
///
/// A background service keeps the environment captured when it was launched, so
/// `PATH` and tool roots written by an installation completed afterwards stay
/// invisible to it; on Windows the registry values are the current ones.
public enum ToolDiscoveryEnvironment {
  public static func current() -> [String: String] {
    var environment = ProcessInfo.processInfo.environment
    #if os(Windows)
      let machineKey = #"SYSTEM\CurrentControlSet\Control\Session Manager\Environment"#
      let path = [
        registeredValue("Path", root: HKEY_LOCAL_MACHINE, subkey: machineKey),
        registeredValue("Path", root: HKEY_CURRENT_USER, subkey: "Environment"),
        environment.first(where: { $0.key.caseInsensitiveCompare("PATH") == .orderedSame })?.value,
      ].compactMap { $0 }.filter { !$0.isEmpty }
      environment = environment.filter { $0.key.caseInsensitiveCompare("PATH") != .orderedSame }
      environment["PATH"] = path.joined(separator: ";")
      for name in [
        "PNPM_HOME", "NPM_CONFIG_PREFIX", "YARN_GLOBAL_FOLDER", "BUN_INSTALL", "CARGO_HOME",
        "VOLTA_HOME",
        "NVM_HOME", "NVM_SYMLINK",
        "CODEX_BRIDGE_CODEX_EXECUTABLE",
        "CODEX_BRIDGE_DEEPSEEK_HARNESS_ROOT", "DEEPSEEK_HARNESS_ROOT",
        "CODEX_BRIDGE_DEEPSEEK_HARNESS_EXECUTABLE", "DEEPSEEK_HARNESS_EXECUTABLE",
        "CODEX_BRIDGE_DEEPSEEK_HARNESS_CONFIGURATION", "DEEPSEEK_HARNESS_CONFIGURATION",
      ] {
        let value =
          registeredValue(name, root: HKEY_CURRENT_USER, subkey: "Environment")
          ?? registeredValue(
            name,
            root: HKEY_LOCAL_MACHINE,
            subkey: machineKey
          )
        guard let value, !value.isEmpty else { continue }
        environment = environment.filter { $0.key.caseInsensitiveCompare(name) != .orderedSame }
        environment[name] = value
      }
    #endif
    return environment
  }

  #if os(Windows)
    private static func registeredValue(_ name: String, root: HKEY?, subkey: String) -> String? {
      var handle: HKEY?
      let status = subkey.withCString(encodedAs: UTF16.self) {
        RegOpenKeyExW(root, $0, 0, REGSAM(KEY_QUERY_VALUE), &handle)
      }
      guard status == ERROR_SUCCESS, let handle else { return nil }
      defer { RegCloseKey(handle) }
      var type: DWORD = 0
      var byteCount: DWORD = 0
      let measured = name.withCString(encodedAs: UTF16.self) {
        RegQueryValueExW(handle, $0, nil, &type, nil, &byteCount)
      }
      guard measured == ERROR_SUCCESS, byteCount > 0, byteCount <= 65_536,
        type == DWORD(REG_SZ) || type == DWORD(REG_EXPAND_SZ)
      else { return nil }
      var buffer = [WCHAR](repeating: 0, count: Int(byteCount) / 2 + 1)
      let read = name.withCString(encodedAs: UTF16.self) { valueName in
        buffer.withUnsafeMutableBytes {
          RegQueryValueExW(
            handle, valueName, nil, &type,
            $0.baseAddress?.assumingMemoryBound(to: BYTE.self), &byteCount
          )
        }
      }
      guard read == ERROR_SUCCESS else { return nil }
      let value = String(decoding: buffer.prefix(while: { $0 != 0 }), as: UTF16.self)
      guard type == DWORD(REG_EXPAND_SZ) else { return value }
      return value.withCString(encodedAs: UTF16.self) { source in
        let count = ExpandEnvironmentStringsW(source, nil, 0)
        guard count > 0, count <= 32_768 else { return nil }
        var expanded = [WCHAR](repeating: 0, count: Int(count))
        let written = ExpandEnvironmentStringsW(source, &expanded, count)
        guard written > 0, written <= count else { return nil }
        return String(decoding: expanded.prefix(while: { $0 != 0 }), as: UTF16.self)
      }
    }
  #endif
}
