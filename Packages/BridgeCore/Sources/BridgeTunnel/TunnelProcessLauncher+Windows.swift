#if os(Windows)
  import Foundation
  import WinSDK

  /// Environment variable names carrying the tunnel secrets into the helper
  /// process. The helper reads them through `env:VARNAME` references, so the
  /// values never appear in argv or on disk.
  package enum WindowsTunnelEnvironment {
    package static let runtimeKeyVariable = "CODEX_BRIDGE_TUNNEL_API_KEY"
    package static let headerSecretVariable = "CODEX_BRIDGE_TUNNEL_TOKEN"
  }

  final class TunnelSpawnedProcess: @unchecked Sendable {
    let pid: Int32
    let stdout: RedactedOutputBuffer
    let stderr: RedactedOutputBuffer
    private let stdoutReader: TunnelPipeReader
    private let stderrReader: TunnelPipeReader
    private let lock = NSLock()
    private var processHandle: HANDLE
    private var jobHandle: HANDLE
    private var exit: TunnelChildExit?
    private var terminationClaimed = false
    private var handlesClosed = false

    init(
      pid: Int32,
      processHandle: HANDLE,
      jobHandle: HANDLE,
      stdout: RedactedOutputBuffer,
      stderr: RedactedOutputBuffer,
      stdoutHandle: HANDLE,
      stderrHandle: HANDLE
    ) {
      self.pid = pid
      self.processHandle = processHandle
      self.jobHandle = jobHandle
      self.stdout = stdout
      self.stderr = stderr
      stdoutReader = TunnelPipeReader(handle: stdoutHandle, buffer: stdout)
      stderrReader = TunnelPipeReader(handle: stderrHandle, buffer: stderr)
      stdoutReader.start()
      stderrReader.start()
    }

    deinit {
      let exited = lock.withLock { resolveExitLocked() != nil }
      if !exited {
        _ = TerminateProcess(processHandle, 1)
        closeJobTreeLocked()
      }
      stdoutReader.waitUntilFinished()
      stderrReader.waitUntilFinished()
      closeHandles()
    }

    func pollExit() -> TunnelChildExit? {
      let resolved = lock.withLock { resolveExitLocked() }
      if resolved != nil {
        stdoutReader.waitUntilFinished()
        stderrReader.waitUntilFinished()
        closeHandles()
      }
      return resolved
    }

    func beginTermination() -> Bool {
      lock.withLock {
        guard resolveExitLocked() == nil, !terminationClaimed else { return false }
        terminationClaimed = true
        return TerminateProcess(processHandle, 1)
      }
    }

    func escalateTermination() {
      lock.withLock {
        guard resolveExitLocked() == nil else { return }
        closeJobTreeLocked()
      }
    }

    private func resolveExitLocked() -> TunnelChildExit? {
      if let exit { return exit }
      guard WaitForSingleObject(processHandle, 0) == WAIT_OBJECT_0 else { return nil }
      var code: DWORD = 0
      _ = GetExitCodeProcess(processHandle, &code)
      let resolved = TunnelChildExit(code: Int32(bitPattern: code))
      exit = resolved
      return resolved
    }

    private func closeJobTreeLocked() {
      guard jobHandle != INVALID_HANDLE_VALUE else { return }
      _ = CloseHandle(jobHandle)
      jobHandle = INVALID_HANDLE_VALUE
    }

    private func closeHandles() {
      lock.withLock {
        guard !handlesClosed else { return }
        handlesClosed = true
        if processHandle != INVALID_HANDLE_VALUE {
          _ = CloseHandle(processHandle)
          processHandle = INVALID_HANDLE_VALUE
        }
        if jobHandle != INVALID_HANDLE_VALUE {
          _ = CloseHandle(jobHandle)
          jobHandle = INVALID_HANDLE_VALUE
        }
      }
    }
  }

  struct TunnelProcessLauncher: Sendable {
    func spawn(
      verifiedHelper: TunnelVerifiedHelper,
      helperVerifier: TunnelHelperVerifier,
      arguments: [String],
      runtimeKey: Data,
      localMCPHeaderSecret: Data,
      runtimeDirectory: URL,
      sensitiveValues: [String],
      outputLimit: Int
    ) throws -> TunnelSpawnedProcess {
      let stdoutPipe = try Self.makeInheritablePipe()
      let stderrPipe = try Self.makeInheritablePipe()
      let stdinHandle = try Self.openNullDevice()
      var succeeded = false
      defer {
        if !succeeded {
          for handle in [
            stdoutPipe.read, stdoutPipe.write, stderrPipe.read, stderrPipe.write, stdinHandle,
          ]
          where handle != INVALID_HANDLE_VALUE {
            _ = CloseHandle(handle)
          }
        }
      }
      _ = SetHandleInformation(stdoutPipe.read, DWORD(HANDLE_FLAG_INHERIT), 0)
      _ = SetHandleInformation(stderrPipe.read, DWORD(HANDLE_FLAG_INHERIT), 0)

      var startup = STARTUPINFOW()
      startup.cb = DWORD(MemoryLayout<STARTUPINFOW>.size)
      startup.dwFlags = DWORD(STARTF_USESTDHANDLES)
      startup.hStdInput = stdinHandle
      startup.hStdOutput = stdoutPipe.write
      startup.hStdError = stderrPipe.write
      var processInformation = PROCESS_INFORMATION()
      var commandLine =
        Array(
          Self.windowsCommandLine(
            [WindowsTunnelPathRules.normalize(verifiedHelper.executable.path)] + arguments
          ).utf16
        ) + [WCHAR(0)]
      let runtimePath = WindowsTunnelPathRules.normalize(runtimeDirectory.standardizedFileURL.path)
      let environmentBlock = Self.windowsEnvironmentBlock(
        runtimePath: runtimePath,
        additions: [
          (
            WindowsTunnelEnvironment.runtimeKeyVariable, String(decoding: runtimeKey, as: UTF8.self)
          ),
          (
            WindowsTunnelEnvironment.headerSecretVariable,
            String(decoding: localMCPHeaderSecret, as: UTF8.self)
          ),
          ("TMP", runtimePath),
          ("TEMP", runtimePath),
          ("CODEX_HOME", WindowsTunnelPathRules.join(runtimePath, "codex-home")),
        ]
      )
      let launched = commandLine.withUnsafeMutableBufferPointer { commandWide in
        environmentBlock.withCString(encodedAs: UTF16.self) { environmentWide in
          runtimePath.withCString(encodedAs: UTF16.self) { workingWide in
            CreateProcessW(
              nil,
              commandWide.baseAddress,
              nil,
              nil,
              true,
              DWORD(CREATE_UNICODE_ENVIRONMENT) | DWORD(CREATE_NO_WINDOW),
              UnsafeMutableRawPointer(mutating: environmentWide),
              workingWide,
              &startup,
              &processInformation
            )
          }
        }
      }
      guard launched else { throw TunnelManagerError.launchFailed }
      _ = CloseHandle(processInformation.hThread)
      _ = CloseHandle(stdinHandle)
      _ = CloseHandle(stdoutPipe.write)
      _ = CloseHandle(stderrPipe.write)
      do {
        let jobHandle = try Self.makeJobObject(assigning: processInformation.hProcess)
        try helperVerifier.verifyRunning(
          processID: Int32(bitPattern: processInformation.dwProcessId),
          expectedIdentity: verifiedHelper.codeIdentity
        )
        let stdout = RedactedOutputBuffer(limit: outputLimit, sensitiveValues: sensitiveValues)
        let stderr = RedactedOutputBuffer(limit: outputLimit, sensitiveValues: sensitiveValues)
        succeeded = true
        return TunnelSpawnedProcess(
          pid: Int32(bitPattern: processInformation.dwProcessId),
          processHandle: processInformation.hProcess,
          jobHandle: jobHandle,
          stdout: stdout,
          stderr: stderr,
          stdoutHandle: stdoutPipe.read,
          stderrHandle: stderrPipe.read
        )
      } catch {
        _ = TerminateProcess(processInformation.hProcess, 1)
        _ = CloseHandle(processInformation.hProcess)
        throw error
      }
    }

    private static func makeJobObject(assigning processHandle: HANDLE) throws -> HANDLE {
      let job = CreateJobObjectW(nil, nil)
      guard let job, job != INVALID_HANDLE_VALUE else {
        throw TunnelManagerError.launchFailed
      }
      var information = JOBOBJECT_EXTENDED_LIMIT_INFORMATION()
      information.BasicLimitInformation.LimitFlags = DWORD(JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE)
      let size = DWORD(MemoryLayout<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>.size)
      let configured = withUnsafeMutablePointer(to: &information) { pointer in
        SetInformationJobObject(job, JobObjectExtendedLimitInformation, pointer, size)
      }
      guard configured, AssignProcessToJobObject(job, processHandle) else {
        _ = CloseHandle(job)
        throw TunnelManagerError.launchFailed
      }
      return job
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
        throw TunnelManagerError.launchFailed
      }
      return (readHandle, writeHandle)
    }

    private static func openNullDevice() throws -> HANDLE {
      var security = SECURITY_ATTRIBUTES()
      security.nLength = DWORD(MemoryLayout<SECURITY_ATTRIBUTES>.size)
      security.bInheritHandle = true
      let handle: HANDLE? = "NUL".withCString(encodedAs: UTF16.self) {
        CreateFileW(
          $0,
          DWORD(GENERIC_READ),
          DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE),
          &security,
          DWORD(OPEN_EXISTING),
          0,
          nil
        )
      }
      guard let handle, handle != INVALID_HANDLE_VALUE else {
        throw TunnelManagerError.launchFailed
      }
      return handle
    }

    /// Inherits the current environment and upserts the tunnel additions, so
    /// the helper sees the injected secrets plus the runtime temp directory.
    private static func windowsEnvironmentBlock(
      runtimePath: String,
      additions: [(String, String)]
    ) -> String {
      var entries = currentEnvironmentEntries()
      for (name, value) in additions {
        if let index = entries.firstIndex(where: { $0.hasPrefix(name + "=") }) {
          entries[index] = name + "=" + value
        } else {
          entries.append(name + "=" + value)
        }
      }
      return entries.joined(separator: "\0") + "\0\0"
    }

    private static func currentEnvironmentEntries() -> [String] {
      guard let block = GetEnvironmentStringsW() else { return [] }
      defer { _ = FreeEnvironmentStringsW(block) }
      var entries: [String] = []
      var cursor = block
      while cursor.pointee != 0 {
        var end = cursor
        while end.pointee != 0 { end += 1 }
        let units = Array(UnsafeBufferPointer(start: cursor, count: end - cursor))
        entries.append(String(decoding: units, as: UTF16.self))
        cursor = end + 1
      }
      return entries
    }

    private static func windowsCommandLine(_ arguments: [String]) -> String {
      arguments.map(Self.windowsArgument).joined(separator: " ")
    }

    /// MSVC command-line quoting; arguments are quoted when they contain
    /// whitespace or quotes (same rules as the shared process runner).
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
  }

  private final class TunnelPipeReader: @unchecked Sendable {
    private let handle: HANDLE
    private let buffer: RedactedOutputBuffer
    private let lock = NSLock()
    private var started = false
    private var finished = false

    init(handle: HANDLE, buffer: RedactedOutputBuffer) {
      self.handle = handle
      self.buffer = buffer
    }

    func start() {
      lock.withLock {
        guard !started else { return }
        started = true
      }
      Thread.detachNewThread { [self] in
        run()
      }
    }

    func waitUntilFinished() {
      let deadline = Date().addingTimeInterval(3)
      while Date() < deadline {
        if lock.withLock({ finished }) { return }
        Thread.sleep(forTimeInterval: 0.02)
      }
    }

    private func run() {
      var bytes = [UInt8](repeating: 0, count: 16 * 1024)
      while true {
        var received: DWORD = 0
        let capacity = bytes.count
        let succeeded = bytes.withUnsafeMutableBytes { raw in
          ReadFile(handle, raw.baseAddress, DWORD(capacity), &received, nil)
        }
        guard succeeded, received > 0 else { break }
        buffer.append(Data(bytes.prefix(Int(received))))
      }
      buffer.finish()
      _ = CloseHandle(handle)
      lock.withLock { finished = true }
    }
  }
#endif
