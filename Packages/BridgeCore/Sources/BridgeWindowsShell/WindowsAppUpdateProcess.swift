#if os(Windows)
  import Foundation
  import WinSDK

  enum WindowsAppUpdateProcessError: Error {
    case launchFailed(Int32)

    var code: Int32 {
      switch self {
      case .launchFailed(let code): return code
      }
    }
  }

  enum WindowsAppUpdateProcessLauncher {
    @discardableResult
    static func launch(
      executable: String,
      arguments: [String],
      workingDirectory: String?,
      waitTimeoutMilliseconds: DWORD? = nil
    ) throws -> DWORD {
      var commandLine = [WCHAR](quote(executable).utf16)
      for argument in arguments {
        commandLine.append(WCHAR(32))
        commandLine.append(contentsOf: quote(argument).utf16)
      }
      commandLine.append(0)

      var startupInfo = STARTUPINFOW()
      startupInfo.cb = DWORD(MemoryLayout<STARTUPINFOW>.size)
      var processInfo = PROCESS_INFORMATION()
      let launched = executable.withCString(encodedAs: UTF16.self) { applicationName in
        workingDirectory.map { directory in
          directory.withCString(encodedAs: UTF16.self) { directoryName in
            create(
              applicationName: applicationName,
              commandLine: &commandLine,
              workingDirectory: directoryName,
              startupInfo: &startupInfo,
              processInfo: &processInfo
            )
          }
        }
          ?? create(
            applicationName: applicationName,
            commandLine: &commandLine,
            workingDirectory: nil,
            startupInfo: &startupInfo,
            processInfo: &processInfo
          )
      }
      guard launched else {
        throw WindowsAppUpdateProcessError.launchFailed(Int32(bitPattern: GetLastError()))
      }
      let processID = processInfo.dwProcessId
      if let waitTimeoutMilliseconds {
        let waitResult = WaitForSingleObject(processInfo.hProcess, waitTimeoutMilliseconds)
        guard waitResult == WAIT_OBJECT_0 else {
          _ = TerminateProcess(processInfo.hProcess, 1)
          _ = CloseHandle(processInfo.hProcess)
          _ = CloseHandle(processInfo.hThread)
          throw WindowsAppUpdateProcessError.launchFailed(
            Int32(bitPattern: DWORD(WAIT_TIMEOUT))
          )
        }
        var exitCode: DWORD = 1
        guard GetExitCodeProcess(processInfo.hProcess, &exitCode) else {
          let errorCode = GetLastError()
          _ = CloseHandle(processInfo.hProcess)
          _ = CloseHandle(processInfo.hThread)
          throw WindowsAppUpdateProcessError.launchFailed(
            Int32(bitPattern: errorCode)
          )
        }
        _ = CloseHandle(processInfo.hProcess)
        _ = CloseHandle(processInfo.hThread)
        guard exitCode == 0 else {
          throw WindowsAppUpdateProcessError.launchFailed(Int32(bitPattern: exitCode))
        }
        return processID
      }
      _ = CloseHandle(processInfo.hProcess)
      _ = CloseHandle(processInfo.hThread)
      return processID
    }

    private static func create(
      applicationName: UnsafePointer<WCHAR>,
      commandLine: inout [WCHAR],
      workingDirectory: UnsafePointer<WCHAR>?,
      startupInfo: inout STARTUPINFOW,
      processInfo: inout PROCESS_INFORMATION
    ) -> Bool {
      commandLine.withUnsafeMutableBufferPointer { commandLine in
        CreateProcessW(
          applicationName,
          commandLine.baseAddress,
          nil,
          nil,
          false,
          DWORD(CREATE_NO_WINDOW) | DWORD(DETACHED_PROCESS),
          nil,
          workingDirectory,
          &startupInfo,
          &processInfo
        )
      }
    }

    static func quote(_ argument: String) -> String {
      guard !argument.isEmpty else { return "\"\"" }
      guard argument.contains(where: { $0 == " " || $0 == "\t" || $0 == "\"" }) else {
        return argument
      }

      var result = "\""
      var backslashes = 0
      for character in argument {
        if character == "\\" {
          backslashes += 1
          continue
        }
        if character == "\"" {
          result += String(repeating: "\\", count: backslashes * 2 + 1)
          result.append(character)
          backslashes = 0
          continue
        }
        if backslashes > 0 {
          result += String(repeating: "\\", count: backslashes)
          backslashes = 0
        }
        result.append(character)
      }
      if backslashes > 0 {
        result += String(repeating: "\\", count: backslashes * 2)
      }
      result.append("\"")
      return result
    }
  }

  enum WindowsAppUpdateRegistry {
    private static let keyReadAccess: REGSAM = 0x0002_0019

    static func stringValue(keyPath: String, valueName: String) -> String? {
      var key: HKEY?
      let openStatus = keyPath.withCString(encodedAs: UTF16.self) { path in
        RegOpenKeyExW(HKEY_CURRENT_USER, path, 0, keyReadAccess, &key)
      }
      guard openStatus == ERROR_SUCCESS, let key else { return nil }
      defer { RegCloseKey(key) }

      var type: DWORD = 0
      var byteCount: DWORD = 0
      let queryStatus = valueName.withCString(encodedAs: UTF16.self) { name in
        RegQueryValueExW(key, name, nil, &type, nil, &byteCount)
      }
      guard queryStatus == ERROR_SUCCESS, byteCount > 0, type == DWORD(REG_SZ) else {
        return nil
      }
      var buffer = [WCHAR](repeating: 0, count: Int(byteCount) / MemoryLayout<WCHAR>.size)
      let readStatus = valueName.withCString(encodedAs: UTF16.self) { name in
        buffer.withUnsafeMutableBytes { bytes in
          RegQueryValueExW(
            key,
            name,
            nil,
            &type,
            bytes.baseAddress?.assumingMemoryBound(to: BYTE.self),
            &byteCount
          )
        }
      }
      guard readStatus == ERROR_SUCCESS else { return nil }
      let value = String(decoding: buffer.prefix(while: { $0 != 0 }), as: UTF16.self)
      return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : value
    }
  }

  struct WindowsPortableUpdateConfiguration: Codable, Sendable {
    let packagePath: String
    let applicationDirectory: String
    let applicationExecutable: String
    let serviceExecutable: String
    let processID: DWORD
    let payloadManifest: String
    let helperScript: String
    let configurationPath: String
    let stagingPath: String?
    let installerProcessID: DWORD?
    let expectedVersion: String?
    let failureReceiptPath: String?
  }
#endif
