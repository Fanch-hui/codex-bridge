import Foundation

#if os(macOS)
  @preconcurrency import AppKit
#elseif os(Windows)
  import WinSDK
#endif

extension AgentSetupLoginLauncher {
  static func openTerminal(script: URL) throws {
    #if os(macOS)
      guard NSWorkspace.shared.openFile(script.path, withApplication: "Terminal") else {
        throw AgentSetupLoginLauncherError.terminalUnavailable
      }
    #elseif os(Windows)
      try openWindowsTerminal(script: script)
    #elseif os(Linux)
      try openLinuxTerminal(script: script)
    #else
      throw AgentSetupLoginLauncherError.terminalUnavailable
    #endif
  }
}

#if os(Linux)
  extension AgentSetupLoginLauncher {
    private static func openLinuxTerminal(script: URL) throws {
      let candidates: [(String, [String])] = [
        ("x-terminal-emulator", ["-e"]), ("gnome-terminal", ["--wait", "--"]),
        ("konsole", ["--separate", "-e"]), ("xterm", ["-e"]),
        ("kitty", []), ("alacritty", ["-e"]),
      ]
      let inherited = ProcessInfo.processInfo.environment
      let directories = (inherited["PATH"] ?? "/usr/local/bin:/usr/bin:/bin").split(separator: ":")
        .filter { $0.hasPrefix("/") }
      let displayKeys: Set<String> = [
        "DISPLAY", "WAYLAND_DISPLAY", "XAUTHORITY", "XDG_RUNTIME_DIR", "DBUS_SESSION_BUS_ADDRESS",
      ]
      var terminalEnvironment = AgentSetupLoginScript.environment([:], inherited: inherited)
      for (key, value) in inherited where displayKeys.contains(key) {
        terminalEnvironment[key] = value
      }
      for (name, options) in candidates {
        guard
          let executable = directories.map({ "\($0)/\(name)" }).first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
          })
        else { continue }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = options + ["/bin/sh", script.path]
        process.environment = terminalEnvironment
        process.currentDirectoryURL = script.deletingLastPathComponent()
        do {
          try process.run()
          return
        } catch { continue }
      }
      throw AgentSetupLoginLauncherError.terminalUnavailable
    }
  }
#endif

#if os(Windows)
  extension AgentSetupLoginLauncher {
    private static func openWindowsTerminal(script: URL) throws {
      var systemPath = [WCHAR](repeating: 0, count: 32_768)
      let count = systemPath.withUnsafeMutableBufferPointer {
        GetSystemDirectoryW($0.baseAddress, UINT($0.count))
      }
      guard count > 0, Int(count) < systemPath.count else {
        throw AgentSetupLoginLauncherError.terminalUnavailable
      }
      let directory = String(decoding: systemPath.prefix(Int(count)), as: UTF16.self)
      let executable = directory + "\\WindowsPowerShell\\v1.0\\powershell.exe"
      guard FileManager.default.fileExists(atPath: executable) else {
        throw AgentSetupLoginLauncherError.terminalUnavailable
      }
      let arguments = [
        executable, "-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", script.path,
      ]
      var commandLine =
        Array(
          arguments.map(AgentSetupLoginScript.windowsQuote)
            .joined(separator: " ").utf16) + [0]
      let entries = AgentSetupLoginScript.environment([:]).sorted {
        $0.key.lowercased() < $1.key.lowercased()
      }.map { "\($0.key)=\($0.value)\0" }.joined()
      var environment = Array(entries.utf16) + [0]
      var startup = STARTUPINFOW()
      startup.cb = DWORD(MemoryLayout<STARTUPINFOW>.size)
      var information = PROCESS_INFORMATION()
      let launched = executable.withCString(encodedAs: UTF16.self) { application in
        script.deletingLastPathComponent().path.withCString(encodedAs: UTF16.self) { cwd in
          commandLine.withUnsafeMutableBufferPointer { line in
            environment.withUnsafeMutableBufferPointer { variables in
              CreateProcessW(
                application, line.baseAddress, nil, nil, false,
                DWORD(CREATE_NEW_CONSOLE) | DWORD(CREATE_UNICODE_ENVIRONMENT),
                variables.baseAddress.map(UnsafeMutableRawPointer.init), cwd, &startup, &information
              )
            }
          }
        }
      }
      guard launched else {
        throw AgentSetupLoginLauncherError.launchFailed(Int32(bitPattern: GetLastError()))
      }
      _ = CloseHandle(information.hThread)
      _ = CloseHandle(information.hProcess)
    }
  }
#endif
