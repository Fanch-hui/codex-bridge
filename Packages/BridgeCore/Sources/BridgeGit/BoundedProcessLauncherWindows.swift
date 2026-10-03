#if os(Windows)
  import Foundation
  import WinSDK

  enum BoundedProcessPlatformLauncher {
    static func spawn(
      _ configuration: BoundedProcessConfiguration
    ) throws -> BoundedProcessChild {
      let outputPipe = try Self.makeInheritablePipe()
      let errorPipe = try Self.makeInheritablePipe()
      var succeeded = false
      defer {
        if !succeeded {
          for handle in [outputPipe.read, outputPipe.write, errorPipe.read, errorPipe.write]
          where handle != INVALID_HANDLE_VALUE {
            _ = CloseHandle(handle)
          }
        }
      }
      // stdin: the NUL device, inheritable for the child.
      var inheritable = SECURITY_ATTRIBUTES()
      inheritable.nLength = DWORD(MemoryLayout<SECURITY_ATTRIBUTES>.size)
      inheritable.bInheritHandle = true
      let stdinHandle: HANDLE = "NUL".withCString(encodedAs: UTF16.self) {
        CreateFileW(
          $0,
          DWORD(GENERIC_READ),
          DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE),
          &inheritable,
          DWORD(OPEN_EXISTING),
          0,
          nil
        )
      }
      defer {
        if !succeeded, stdinHandle != INVALID_HANDLE_VALUE {
          _ = CloseHandle(stdinHandle)
        }
      }
      // The child inherits the pipe write ends; the parent's read ends stay private.
      _ = SetHandleInformation(outputPipe.read, DWORD(HANDLE_FLAG_INHERIT), 0)
      _ = SetHandleInformation(errorPipe.read, DWORD(HANDLE_FLAG_INHERIT), 0)

      var commandLine =
        Array(
          Self.windowsCommandLine(
            [configuration.executableURL.path] + configuration.arguments
          ).utf16
        ) + [WCHAR(0)]
      let environmentBlock = Self.windowsEnvironmentBlock(configuration.environment)
      var startup = STARTUPINFOW()
      startup.cb = DWORD(MemoryLayout<STARTUPINFOW>.size)
      var processInformation = PROCESS_INFORMATION()
      let workingPath = configuration.workingDirectory.url.path
      let launched = commandLine.withUnsafeMutableBufferPointer { commandWide in
        environmentBlock.withCString(encodedAs: UTF16.self) { environmentWide in
          workingPath.withCString(encodedAs: UTF16.self) { workingWide in
            CreateProcessW(
              nil,
              commandWide.baseAddress,
              nil,
              nil,
              true,
              // The desktop shell is a Windows GUI subsystem process. Without
              // CREATE_NO_WINDOW, console tools such as Git receive a newly
              // allocated console window for each status refresh.
              DWORD(CREATE_UNICODE_ENVIRONMENT) | DWORD(CREATE_NO_WINDOW),
              UnsafeMutableRawPointer(mutating: environmentWide),
              workingWide,
              &startup,
              &processInformation
            )
          }
        }
      }
      guard launched else { throw BoundedProcessError.launchFailed }
      _ = CloseHandle(processInformation.hThread)
      _ = CloseHandle(stdinHandle)
      _ = CloseHandle(outputPipe.write)
      _ = CloseHandle(errorPipe.write)
      succeeded = true
      return BoundedProcessChild(
        pid: Int32(bitPattern: processInformation.dwProcessId),
        processHandle: processInformation.hProcess,
        outputHandle: outputPipe.read,
        errorHandle: errorPipe.read,
        maximumStandardOutputBytes: configuration.maximumStandardOutputBytes,
        maximumStandardErrorBytes: configuration.maximumStandardErrorBytes
      )
    }

    private static func makeInheritablePipe() throws -> (read: HANDLE, write: HANDLE) {
      var security = SECURITY_ATTRIBUTES()
      security.nLength = DWORD(MemoryLayout<SECURITY_ATTRIBUTES>.size)
      security.bInheritHandle = true
      var read: HANDLE? = nil
      var write: HANDLE? = nil
      guard CreatePipe(&read, &write, &security, 0),
        let readHandle = read, let writeHandle = write
      else {
        throw BoundedProcessError.launchFailed
      }
      return (readHandle, writeHandle)
    }

    /// Minimal MSVC command-line quoting; arguments are quoted when they contain
    /// whitespace or quotes.
    private static func windowsCommandLine(_ arguments: [String]) -> String {
      arguments.map(Self.windowsArgument).joined(separator: " ")
    }

    private static func windowsArgument(_ argument: String) -> String {
      let requiresQuoting =
        argument.isEmpty || argument.contains(" ") || argument.contains("\t")
        || argument.contains("\"")
      guard requiresQuoting else { return argument }
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
        } else {
          result += String(repeating: "\\", count: backslashes)
          result.append(character)
        }
        backslashes = 0
      }
      result += String(repeating: "\\", count: backslashes * 2)
      result.append("\"")
      return result
    }

    private static func windowsEnvironmentBlock(_ entries: [String]) -> String {
      entries.joined(separator: "\0") + "\0\0"
    }
  }
#endif
