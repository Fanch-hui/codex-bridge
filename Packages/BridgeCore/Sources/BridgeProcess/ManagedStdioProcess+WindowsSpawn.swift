#if os(Windows)
  import Foundation
  import WinSDK

  extension ManagedStdioProcess {
    private static let procThreadAttributeHandleList: DWORD_PTR = 0x0002_0002

    private struct WindowsLaunch {
      let executable: String
      let arguments: [String]
      let environment: [String: String]
    }

    /// Starts a child with inherited stdio pipes and no console allocation.
    static func spawnWindows(
      argv: [String],
      workingDirectory: String?,
      environment: [String: String],
      standardInput: Pipe,
      standardOutput: Pipe,
      standardError: Pipe?
    ) throws -> (pid: Int32, handle: HANDLE) {
      let launch = try windowsLaunch(argv: argv, environment: environment)
      let stdinRead = standardInput.fileHandleForReading._handle
      let stdinWrite = standardInput.fileHandleForWriting._handle
      let stdoutRead = standardOutput.fileHandleForReading._handle
      let stdoutWrite = standardOutput.fileHandleForWriting._handle
      let stderrRead = standardError?.fileHandleForReading._handle
      let stderrWrite = standardError?.fileHandleForWriting._handle ?? stdoutWrite
      try configurePipeInheritance(
        stdinRead: stdinRead,
        stdinWrite: stdinWrite,
        stdoutRead: stdoutRead,
        stdoutWrite: stdoutWrite,
        stderrRead: stderrRead,
        stderrWrite: stderrWrite
      )
      return try launchWindowsProcess(
        launch: launch,
        workingDirectory: workingDirectory,
        stdinRead: stdinRead,
        stdoutWrite: stdoutWrite,
        stderrWrite: stderrWrite
      )
    }

    private static func windowsLaunch(
      argv: [String],
      environment: [String: String]
    ) throws -> WindowsLaunch {
      guard let executable = argv.first else {
        throw ManagedProcessError.invalidArgument
      }
      let lower = executable.lowercased()
      if lower.hasSuffix(".cmd") || lower.hasSuffix(".bat") {
        let comSpec =
          environment["ComSpec"]
          ?? ProcessInfo.processInfo.environment["ComSpec"]
          ?? "C:\\Windows\\System32\\cmd.exe"
        var batchEnvironment = environment
        batchEnvironment[Self.windowsBatchCommandEnvironmentKey] =
          Self.windowsBatchCommand(argv)
        return WindowsLaunch(
          executable: comSpec,
          arguments: [
            "/d", "/v:off", "/s", "/c",
            "%\(Self.windowsBatchCommandEnvironmentKey)%",
          ],
          environment: batchEnvironment
        )
      }
      return WindowsLaunch(
        executable: executable,
        arguments: Array(argv.dropFirst()),
        environment: environment
      )
    }

    private static func configurePipeInheritance(
      stdinRead: HANDLE,
      stdinWrite: HANDLE,
      stdoutRead: HANDLE,
      stdoutWrite: HANDLE,
      stderrRead: HANDLE?,
      stderrWrite: HANDLE
    ) throws {
      let inheritFlag = DWORD(HANDLE_FLAG_INHERIT)
      guard SetHandleInformation(stdinRead, inheritFlag, inheritFlag),
        SetHandleInformation(stdinWrite, inheritFlag, 0),
        SetHandleInformation(stdoutRead, inheritFlag, 0),
        SetHandleInformation(stdoutWrite, inheritFlag, inheritFlag),
        stderrRead.map({ SetHandleInformation($0, inheritFlag, 0) }) ?? true,
        SetHandleInformation(stderrWrite, inheritFlag, inheritFlag)
      else {
        throw ManagedProcessError.processLaunchFailed(Int32(GetLastError()))
      }
    }

    private static func launchWindowsProcess(
      launch: WindowsLaunch,
      workingDirectory: String?,
      stdinRead: HANDLE,
      stdoutWrite: HANDLE,
      stderrWrite: HANDLE
    ) throws -> (pid: Int32, handle: HANDLE) {
      var processInformation = PROCESS_INFORMATION()
      var commandLine =
        Array(
          windowsCommandLine([launch.executable] + launch.arguments).utf16
        ) + [WCHAR(0)]
      let environmentBlock = windowsEnvironmentBlock(launch.environment)
      let result = try withStartupInfo(
        stdinRead: stdinRead,
        stdoutWrite: stdoutWrite,
        stderrWrite: stderrWrite
      ) { startup in
        createWindowsProcess(
          launch: launch,
          workingDirectory: workingDirectory,
          commandLine: &commandLine,
          environmentBlock: environmentBlock,
          startup: &startup,
          processInformation: &processInformation
        )
      }
      guard result.success else {
        throw ManagedProcessError.processLaunchFailed(Int32(result.error))
      }
      _ = CloseHandle(processInformation.hThread)
      guard let processHandle = processInformation.hProcess else {
        throw ManagedProcessError.processLaunchFailed(Int32(ERROR_INVALID_HANDLE))
      }
      return (pid: Int32(bitPattern: processInformation.dwProcessId), handle: processHandle)
    }

    private static func withStartupInfo<Result>(
      stdinRead: HANDLE,
      stdoutWrite: HANDLE,
      stderrWrite: HANDLE,
      _ body: (inout STARTUPINFOEXW) throws -> Result
    ) throws -> Result {
      var attributeSize: SIZE_T = 0
      _ = InitializeProcThreadAttributeList(nil, 1, 0, &attributeSize)
      guard attributeSize > 0 else {
        throw ManagedProcessError.processLaunchFailed(Int32(GetLastError()))
      }
      let attributeBuffer = UnsafeMutableRawPointer.allocate(
        byteCount: Int(attributeSize),
        alignment: MemoryLayout<Int>.alignment
      )
      let attributeList = OpaquePointer(attributeBuffer)
      defer { attributeBuffer.deallocate() }
      guard InitializeProcThreadAttributeList(attributeList, 1, 0, &attributeSize) else {
        throw ManagedProcessError.processLaunchFailed(Int32(GetLastError()))
      }
      defer { DeleteProcThreadAttributeList(attributeList) }
      var inheritedHandles = [stdinRead, stdoutWrite]
      if stderrWrite != stdoutWrite { inheritedHandles.append(stderrWrite) }
      let handleListSize = SIZE_T(MemoryLayout<HANDLE>.size * inheritedHandles.count)
      return try inheritedHandles.withUnsafeMutableBufferPointer { handles in
        guard
          UpdateProcThreadAttribute(
            attributeList, 0, procThreadAttributeHandleList, handles.baseAddress,
            handleListSize, nil, nil
          )
        else {
          throw ManagedProcessError.processLaunchFailed(Int32(GetLastError()))
        }
        var startup = STARTUPINFOEXW()
        startup.StartupInfo.cb = DWORD(MemoryLayout<STARTUPINFOEXW>.size)
        startup.StartupInfo.dwFlags = DWORD(STARTF_USESTDHANDLES)
        startup.StartupInfo.hStdInput = stdinRead
        startup.StartupInfo.hStdOutput = stdoutWrite
        startup.StartupInfo.hStdError = stderrWrite
        startup.lpAttributeList = attributeList
        return try body(&startup)
      }
    }

    private static func createWindowsProcess(
      launch: WindowsLaunch,
      workingDirectory: String?,
      commandLine: inout [WCHAR],
      environmentBlock: String,
      startup: inout STARTUPINFOEXW,
      processInformation: inout PROCESS_INFORMATION
    ) -> (success: Bool, error: DWORD) {
      if let workingDirectory {
        return workingDirectory.withCString(encodedAs: UTF16.self) { directory in
          createWindowsProcess(
            launch: launch, directory: directory, commandLine: &commandLine,
            environmentBlock: environmentBlock, startup: &startup,
            processInformation: &processInformation
          )
        }
      }
      return createWindowsProcess(
        launch: launch, directory: nil, commandLine: &commandLine,
        environmentBlock: environmentBlock, startup: &startup,
        processInformation: &processInformation
      )
    }

    private static func createWindowsProcess(
      launch: WindowsLaunch,
      directory: UnsafePointer<WCHAR>?,
      commandLine: inout [WCHAR],
      environmentBlock: String,
      startup: inout STARTUPINFOEXW,
      processInformation: inout PROCESS_INFORMATION
    ) -> (success: Bool, error: DWORD) {
      launch.executable.withCString(encodedAs: UTF16.self) { applicationName in
        commandLine.withUnsafeMutableBufferPointer { commandLine in
          environmentBlock.withCString(encodedAs: UTF16.self) { environment in
            let flags =
              DWORD(EXTENDED_STARTUPINFO_PRESENT)
              | DWORD(CREATE_UNICODE_ENVIRONMENT) | DWORD(CREATE_NO_WINDOW)
            let success = CreateProcessW(
              applicationName, commandLine.baseAddress, nil, nil, true, flags,
              UnsafeMutableRawPointer(mutating: environment), directory,
              &startup.StartupInfo, &processInformation
            )
            return (success, success ? DWORD(ERROR_SUCCESS) : GetLastError())
          }
        }
      }
    }

    private static func windowsCommandLine(_ arguments: [String]) -> String {
      arguments.map(windowsArgument).joined(separator: " ")
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

    private static func windowsEnvironmentBlock(_ environment: [String: String]) -> String {
      var values: [String: String] = [:]
      for (name, value) in environment {
        if let existing = values.keys.first(where: {
          windowsEnvironmentNameCompare($0, name) == 2
        }) {
          values.removeValue(forKey: existing)
        }
        values[name] = value
      }
      let entries = values.sorted {
        windowsEnvironmentNameCompare($0.key, $1.key) == 1
      }.map { "\($0.key)=\($0.value)" }
      return entries.joined(separator: "\0") + "\0\0"
    }
    private static func windowsEnvironmentNameCompare(_ lhs: String, _ rhs: String) -> CInt {
      lhs.withCString(encodedAs: UTF16.self) { left in
        rhs.withCString(encodedAs: UTF16.self) { right in
          CompareStringOrdinal(left, -1, right, -1, true)
        }
      }
    }
  }
#endif
