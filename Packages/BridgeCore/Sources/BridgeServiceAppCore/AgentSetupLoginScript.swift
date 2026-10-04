import BridgeIPC
import Foundation

enum AgentSetupLoginScript {
  static let allowedEnvironmentKeys: Set<String> = [
    "PATH", "HOME", "USERPROFILE", "APPDATA", "LOCALAPPDATA", "XDG_CONFIG_HOME", "XDG_DATA_HOME",
    "QODER_CONFIG_DIR", "QODERCN_CONFIG_DIR", "PI_CODING_AGENT_DIR",
    "SystemRoot", "WINDIR", "TEMP", "TMP", "LANG", "LC_ALL", "TERM",
  ]

  static func environment(
    _ supplied: [String: String], inherited: [String: String] = ProcessInfo.processInfo.environment
  ) -> [String: String] {
    #if os(Windows)
      let canonicalKeys = Dictionary(
        uniqueKeysWithValues: allowedEnvironmentKeys.map {
          ($0.uppercased(), $0)
        })
    #endif
    var result: [String: String] = [:]
    for source in [inherited, supplied] {
      for (key, value) in source {
        #if os(Windows)
          guard let canonical = canonicalKeys[key.uppercased()] else { continue }
        #else
          guard allowedEnvironmentKeys.contains(key) else { continue }
          let canonical = key
        #endif
        result[canonical] = value
      }
    }
    return result
  }

  static func posix(_ command: IPCAgentSetupLoginCommand) -> String {
    let entries = environment(command.environment).sorted { $0.key < $1.key }
      .map { posixQuote("\($0.key)=\($0.value)") }
    let invocation = ([posixQuote(command.executablePath)] + command.arguments.map(posixQuote))
      .joined(separator: " ")
    return """
      #!/bin/sh
      printf '%s\\n' \(posixQuote(command.instructions))
      cd \(posixQuote(command.workingDirectory)) || exit 1
      /usr/bin/env -i \(entries.joined(separator: " ")) \(invocation)
      login_status=$?
      printf '\\n%s\\n' '登录操作已结束。请回到 Codex Bridge，点击“我已完成，重新检测”。'
      printf '%s' '按 Enter 关闭终端…'
      IFS= read -r ignored
      exit "$login_status"

      """
  }

  static func powerShell(_ command: IPCAgentSetupLoginCommand) -> String {
    let entries = environment(command.environment).sorted { $0.key < $1.key }
      .map {
        "$start.EnvironmentVariables[\(powerShellQuote($0.key))] = \(powerShellQuote($0.value))"
      }
      .joined(separator: "\n")
    let arguments = command.arguments.map(windowsQuote).joined(separator: " ")
    return """
      $ErrorActionPreference = 'Stop'
      Write-Host \(powerShellQuote(command.instructions))
      $start = New-Object System.Diagnostics.ProcessStartInfo
      $start.FileName = \(powerShellQuote(command.executablePath))
      $start.Arguments = \(powerShellQuote(arguments))
      $start.WorkingDirectory = \(powerShellQuote(command.workingDirectory))
      $start.UseShellExecute = $false
      $start.EnvironmentVariables.Clear()
      \(entries)
      try {
        $login = [System.Diagnostics.Process]::Start($start)
        $login.WaitForExit()
        $loginStatus = $login.ExitCode
        $login.Dispose()
      } catch {
        Write-Host $_.Exception.Message
        $loginStatus = 1
      }
      Write-Host '登录操作已结束。请回到 Codex Bridge，点击“我已完成，重新检测”。'
      [void](Read-Host '按 Enter 关闭终端')
      exit $loginStatus

      """
  }

  static func posixQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
  }

  static func powerShellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
  }

  static func windowsQuote(_ argument: String) -> String {
    var result = "\""
    var backslashes = 0
    for character in argument {
      if character == "\\" {
        backslashes += 1
        continue
      }
      if character == "\"" {
        result += String(repeating: "\\", count: backslashes * 2 + 1)
      } else {
        result += String(repeating: "\\", count: backslashes)
      }
      result.append(character)
      backslashes = 0
    }
    result += String(repeating: "\\", count: backslashes * 2)
    return result + "\""
  }
}
