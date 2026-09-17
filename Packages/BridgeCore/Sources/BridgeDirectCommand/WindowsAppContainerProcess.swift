#if os(Windows)
  import BridgeAgentCore
  import Foundation
  import WinSDK

  public final class WindowsAppContainerProcess: @unchecked Sendable {
    public let pid: Int32
    private var processHandle: HANDLE
    private var threadHandle: HANDLE
    private var jobHandle: HANDLE
    private var stdinWriteHandle: HANDLE
    private let containerName: String
    private let appContainerSid: PSID
    private let reader: OutputReader
    private let lock = NSLock()
    private var closed = false
    private var cachedTermination: DirectProcessTermination?

    private static let procThreadAttributeSecurityCapabilities: DWORD_PTR = 0x0002_0009
    private static let procThreadAttributeHandleList: DWORD_PTR = 0x0002_0002

    private struct SECURITY_CAPABILITIES {
      var appContainerSid: PSID?
      var capabilities: UnsafeMutableRawPointer?
      var capabilityCount: DWORD
      var reserved: DWORD
    }

    private typealias CreateAppContainerProfileFn =
      @convention(c) (
        UnsafePointer<WCHAR>?,
        UnsafePointer<WCHAR>?,
        UnsafePointer<WCHAR>?,
        UnsafeMutableRawPointer?,
        DWORD,
        UnsafeMutablePointer<PSID?>?
      ) -> HRESULT

    private typealias DeleteAppContainerProfileFn =
      @convention(c) (
        UnsafePointer<WCHAR>?
      ) -> HRESULT

    private typealias DeriveAppContainerSidFn =
      @convention(c) (
        UnsafePointer<WCHAR>?,
        UnsafeMutablePointer<PSID?>?
      ) -> HRESULT

    public init(
      argv: [String],
      workingDirectory: String?,
      environment: [String: String],
      onOutput: @escaping @Sendable (Data) -> Void
    ) throws {
      guard let executable = argv.first, !executable.isEmpty else {
        throw DirectProcessError.invalidArgument
      }

      guard let userenv = "userenv.dll".withCString(encodedAs: UTF16.self, { LoadLibraryW($0) })
      else {
        throw DirectProcessError.sandboxUnavailable
      }
      defer { _ = FreeLibrary(userenv) }

      guard
        let createProfilePtr = "CreateAppContainerProfile".withCString({
          GetProcAddress(userenv, $0)
        }),
        "DeleteAppContainerProfile".withCString({
          GetProcAddress(userenv, $0)
        }) != nil,
        let deriveSidPtr = "DeriveAppContainerSidFromAppContainerName".withCString({
          GetProcAddress(userenv, $0)
        })
      else {
        throw DirectProcessError.sandboxUnavailable
      }

      let createProfile = unsafeBitCast(createProfilePtr, to: CreateAppContainerProfileFn.self)
      let deriveSid = unsafeBitCast(deriveSidPtr, to: DeriveAppContainerSidFn.self)

      let uniqueName =
        "CodexBridge.Direct.\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
      var sidPointer: PSID?
      let hr = uniqueName.withCString(encodedAs: UTF16.self) { nameW in
        createProfile(nameW, nameW, nameW, nil, 0, &sidPointer)
      }
      if hr != 0 && hr != HRESULT(bitPattern: 0x8007_00B7) {
        throw DirectProcessError.sandboxUnavailable
      }
      if sidPointer == nil {
        let deriveHr = uniqueName.withCString(encodedAs: UTF16.self) { nameW in
          deriveSid(nameW, &sidPointer)
        }
        guard deriveHr == 0, let sid = sidPointer else {
          throw DirectProcessError.sandboxUnavailable
        }
        sidPointer = sid
      }
      guard let sid = sidPointer else {
        throw DirectProcessError.sandboxUnavailable
      }
      self.containerName = uniqueName
      self.appContainerSid = sid

      if let workingDirectory, !workingDirectory.isEmpty {
        _ = Self.grantAccess(to: workingDirectory, for: sid)
      }

      var stdinRead: HANDLE?
      var stdinWrite: HANDLE?
      var stdoutRead: HANDLE?
      var stdoutWrite: HANDLE?
      var sa = SECURITY_ATTRIBUTES()
      sa.nLength = DWORD(MemoryLayout<SECURITY_ATTRIBUTES>.size)
      sa.bInheritHandle = true

      guard CreatePipe(&stdinRead, &stdinWrite, &sa, 0),
        let inRead = stdinRead, let inWrite = stdinWrite
      else {
        Self.cleanupProfile(name: uniqueName)
        throw DirectProcessError.sandboxUnavailable
      }
      _ = SetHandleInformation(inWrite, DWORD(HANDLE_FLAG_INHERIT), 0)

      guard CreatePipe(&stdoutRead, &stdoutWrite, &sa, 0),
        let outRead = stdoutRead, let outWrite = stdoutWrite
      else {
        _ = CloseHandle(inRead)
        _ = CloseHandle(inWrite)
        Self.cleanupProfile(name: uniqueName)
        throw DirectProcessError.sandboxUnavailable
      }
      _ = SetHandleInformation(outRead, DWORD(HANDLE_FLAG_INHERIT), 0)

      self.stdinWriteHandle = inWrite

      let job = CreateJobObjectW(nil, nil)
      guard let job, job != INVALID_HANDLE_VALUE else {
        _ = CloseHandle(inRead)
        _ = CloseHandle(inWrite)
        _ = CloseHandle(outRead)
        _ = CloseHandle(outWrite)
        Self.cleanupProfile(name: uniqueName)
        throw DirectProcessError.sandboxUnavailable
      }
      var limitInfo = JOBOBJECT_EXTENDED_LIMIT_INFORMATION()
      limitInfo.BasicLimitInformation.LimitFlags = DWORD(JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE)
      _ = SetInformationJobObject(
        job,
        JobObjectExtendedLimitInformation,
        &limitInfo,
        DWORD(MemoryLayout<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>.size)
      )
      self.jobHandle = job

      var attrSize: SIZE_T = 0
      _ = InitializeProcThreadAttributeList(nil, 2, 0, &attrSize)
      let attrBuffer = UnsafeMutableRawPointer.allocate(
        byteCount: Int(attrSize),
        alignment: MemoryLayout<Int>.alignment
      )
      let attrList = OpaquePointer(attrBuffer)
      defer {
        DeleteProcThreadAttributeList(attrList)
        attrBuffer.deallocate()
      }
      guard InitializeProcThreadAttributeList(attrList, 2, 0, &attrSize) else {
        _ = CloseHandle(inRead)
        _ = CloseHandle(inWrite)
        _ = CloseHandle(outRead)
        _ = CloseHandle(outWrite)
        _ = CloseHandle(job)
        Self.cleanupProfile(name: uniqueName)
        throw DirectProcessError.sandboxUnavailable
      }

      var secCaps = SECURITY_CAPABILITIES(
        appContainerSid: sid,
        capabilities: nil,
        capabilityCount: 0,
        reserved: 0
      )
      let secOk = withUnsafeMutablePointer(to: &secCaps) { secPtr in
        UpdateProcThreadAttribute(
          attrList,
          0,
          Self.procThreadAttributeSecurityCapabilities,
          secPtr,
          SIZE_T(MemoryLayout<SECURITY_CAPABILITIES>.size),
          nil,
          nil
        )
      }

      var inheritedHandles: [HANDLE] = [inRead, outWrite]
      let handleOk = inheritedHandles.withUnsafeMutableBufferPointer { handleBuf in
        UpdateProcThreadAttribute(
          attrList,
          0,
          Self.procThreadAttributeHandleList,
          handleBuf.baseAddress,
          SIZE_T(MemoryLayout<HANDLE>.size * handleBuf.count),
          nil,
          nil
        )
      }

      guard secOk, handleOk else {
        _ = CloseHandle(inRead)
        _ = CloseHandle(inWrite)
        _ = CloseHandle(outRead)
        _ = CloseHandle(outWrite)
        _ = CloseHandle(job)
        Self.cleanupProfile(name: uniqueName)
        throw DirectProcessError.sandboxUnavailable
      }

      var startupInfoEx = STARTUPINFOEXW()
      startupInfoEx.StartupInfo.cb = DWORD(MemoryLayout<STARTUPINFOEXW>.size)
      startupInfoEx.StartupInfo.hStdInput = inRead
      startupInfoEx.StartupInfo.hStdOutput = outWrite
      startupInfoEx.StartupInfo.hStdError = outWrite
      startupInfoEx.StartupInfo.dwFlags = DWORD(STARTF_USESTDHANDLES)
      startupInfoEx.lpAttributeList = attrList

      let commandLineStr = Self.windowsCommandLine(argv)
      var commandLineW = Array(commandLineStr.utf16) + [WCHAR(0)]
      let envBlock = Self.windowsEnvironmentBlock(environment)

      var processInfo = PROCESS_INFORMATION()
      let created = commandLineW.withUnsafeMutableBufferPointer { cmdBuf in
        envBlock.withCString(encodedAs: UTF16.self) { envW in
          if let workingDirectory, !workingDirectory.isEmpty {
            return workingDirectory.withCString(encodedAs: UTF16.self) { workW in
              CreateProcessW(
                nil,
                cmdBuf.baseAddress,
                nil,
                nil,
                true,
                DWORD(EXTENDED_STARTUPINFO_PRESENT) | DWORD(CREATE_UNICODE_ENVIRONMENT)
                  | DWORD(CREATE_NO_WINDOW),
                UnsafeMutableRawPointer(mutating: envW),
                workW,
                &startupInfoEx.StartupInfo,
                &processInfo
              )
            }
          } else {
            return CreateProcessW(
              nil,
              cmdBuf.baseAddress,
              nil,
              nil,
              true,
              DWORD(EXTENDED_STARTUPINFO_PRESENT) | DWORD(CREATE_UNICODE_ENVIRONMENT)
                | DWORD(CREATE_NO_WINDOW),
              UnsafeMutableRawPointer(mutating: envW),
              nil,
              &startupInfoEx.StartupInfo,
              &processInfo
            )
          }
        }
      }

      _ = CloseHandle(inRead)
      _ = CloseHandle(outWrite)

      guard created, let proc = processInfo.hProcess, let thread = processInfo.hThread else {
        _ = CloseHandle(inWrite)
        _ = CloseHandle(outRead)
        _ = CloseHandle(job)
        Self.cleanupProfile(name: uniqueName)
        throw DirectProcessError.processLaunchFailed(Int32(GetLastError()))
      }

      _ = AssignProcessToJobObject(job, proc)
      self.processHandle = proc
      self.threadHandle = thread
      self.pid = Int32(bitPattern: processInfo.dwProcessId)

      let pipeReader = OutputReader(handle: outRead, onOutput: onOutput)
      self.reader = pipeReader
      pipeReader.start()
    }

    deinit {
      close()
    }

    public func writeStdin(_ data: Data) throws {
      lock.lock()
      let handle = stdinWriteHandle
      let isClosed = closed
      lock.unlock()
      guard !isClosed, handle != INVALID_HANDLE_VALUE else {
        throw DirectProcessError.stdinUnavailable
      }
      var totalWritten = 0
      while totalWritten < data.count {
        var written: DWORD = 0
        let chunkCount = min(data.count - totalWritten, 65536)
        let success = data.dropFirst(totalWritten).prefix(chunkCount).withUnsafeBytes { raw in
          WriteFile(handle, raw.baseAddress, DWORD(chunkCount), &written, nil)
        }
        guard success, written > 0 else {
          throw DirectProcessError.stdinUnavailable
        }
        totalWritten += Int(written)
      }
    }

    public func closeStdin() {
      lock.lock()
      let handle = stdinWriteHandle
      stdinWriteHandle = INVALID_HANDLE_VALUE
      lock.unlock()
      if handle != INVALID_HANDLE_VALUE {
        _ = CloseHandle(handle)
      }
    }

    public func terminateGroup() {
      lock.lock()
      let proc = processHandle
      lock.unlock()
      if proc != INVALID_HANDLE_VALUE {
        _ = TerminateProcess(proc, 1)
      }
    }

    public func killGroup() {
      lock.lock()
      let job = jobHandle
      jobHandle = INVALID_HANDLE_VALUE
      let proc = processHandle
      lock.unlock()
      if job != INVALID_HANDLE_VALUE {
        _ = CloseHandle(job)
      }
      if proc != INVALID_HANDLE_VALUE {
        _ = TerminateProcess(proc, 1)
      }
    }

    public var isRunning: Bool {
      lock.lock()
      defer { lock.unlock() }
      guard processHandle != INVALID_HANDLE_VALUE else { return false }
      return WaitForSingleObject(processHandle, 0) != WAIT_OBJECT_0
    }

    public func reapIfExited(gracePeriod: Duration = .milliseconds(200))
      -> DirectProcessTermination?
    {
      lock.lock()
      if let cached = cachedTermination {
        lock.unlock()
        return cached
      }
      let proc = processHandle
      lock.unlock()
      guard proc != INVALID_HANDLE_VALUE else { return .notStarted }

      let ms = DWORD(
        min(
          max(
            0,
            gracePeriod.components.seconds * 1000
              + Int64(gracePeriod.components.attoseconds / 1_000_000_000_000_000)), 60_000))
      let waitRes = WaitForSingleObject(proc, ms)
      if waitRes == WAIT_OBJECT_0 {
        var exitCode: DWORD = 0
        _ = GetExitCodeProcess(proc, &exitCode)
        let termination = DirectProcessTermination.exited(Int32(bitPattern: exitCode))
        lock.lock()
        cachedTermination = termination
        lock.unlock()
        reader.waitUntilFinished()
        return termination
      }
      return nil
    }

    public func waitForExit(timeout: Duration) -> DirectProcessTermination? {
      lock.lock()
      if let cached = cachedTermination {
        lock.unlock()
        return cached
      }
      let proc = processHandle
      lock.unlock()
      guard proc != INVALID_HANDLE_VALUE else { return .notStarted }

      let ms = DWORD(
        min(
          max(
            0,
            timeout.components.seconds * 1000
              + Int64(timeout.components.attoseconds / 1_000_000_000_000_000)), 3_600_000))
      let waitRes = WaitForSingleObject(proc, ms)
      if waitRes == WAIT_OBJECT_0 {
        var exitCode: DWORD = 0
        _ = GetExitCodeProcess(proc, &exitCode)
        let termination = DirectProcessTermination.exited(Int32(bitPattern: exitCode))
        lock.lock()
        cachedTermination = termination
        lock.unlock()
        reader.waitUntilFinished()
        return termination
      }
      return nil
    }

    public func terminateAndWait(
      gracePeriod: Duration = .seconds(1),
      killWait: Duration = .seconds(5)
    ) -> DirectProcessTermination? {
      terminateGroup()
      if let exited = reapIfExited(gracePeriod: gracePeriod) {
        return exited
      }
      killGroup()
      return reapIfExited(gracePeriod: killWait)
    }

    public func drainRemainingOutput() {
      reader.waitUntilFinished()
    }

    public func close() {
      lock.lock()
      guard !closed else {
        lock.unlock()
        return
      }
      closed = true
      let inWrite = stdinWriteHandle
      stdinWriteHandle = INVALID_HANDLE_VALUE
      let proc = processHandle
      processHandle = INVALID_HANDLE_VALUE
      let thread = threadHandle
      threadHandle = INVALID_HANDLE_VALUE
      let job = jobHandle
      jobHandle = INVALID_HANDLE_VALUE
      let name = containerName
      lock.unlock()

      if inWrite != INVALID_HANDLE_VALUE { _ = CloseHandle(inWrite) }
      if proc != INVALID_HANDLE_VALUE {
        _ = TerminateProcess(proc, 1)
        _ = CloseHandle(proc)
      }
      if thread != INVALID_HANDLE_VALUE { _ = CloseHandle(thread) }
      if job != INVALID_HANDLE_VALUE { _ = CloseHandle(job) }
      reader.waitUntilFinished()
      Self.cleanupProfile(name: name)
    }

    private static func cleanupProfile(name: String) {
      guard let userenv = "userenv.dll".withCString(encodedAs: UTF16.self, { LoadLibraryW($0) })
      else { return }
      defer { _ = FreeLibrary(userenv) }
      guard
        let deleteProfilePtr = "DeleteAppContainerProfile".withCString({
          GetProcAddress(userenv, $0)
        })
      else { return }
      let deleteProfile = unsafeBitCast(deleteProfilePtr, to: DeleteAppContainerProfileFn.self)
      _ = name.withCString(encodedAs: UTF16.self) { deleteProfile($0) }
    }

    private static func grantAccess(to path: String, for sid: PSID) -> Bool {
      var ea = EXPLICIT_ACCESS_W()
      ea.grfAccessPermissions = DWORD(0x1000_0000)  // GENERIC_ALL
      ea.grfAccessMode = GRANT_ACCESS
      ea.grfInheritance = DWORD(1 | 2)  // OBJECT_INHERIT_ACE | CONTAINER_INHERIT_ACE
      ea.Trustee.TrusteeForm = TRUSTEE_IS_SID
      ea.Trustee.TrusteeType = TRUSTEE_IS_UNKNOWN
      ea.Trustee.ptstrName = UnsafeMutablePointer<WCHAR>(OpaquePointer(sid))

      var oldDacl: PACL?
      var pSD: PSECURITY_DESCRIPTOR?
      let getRes = path.withCString(encodedAs: UTF16.self) { p in
        GetNamedSecurityInfoW(
          UnsafeMutablePointer(mutating: p),
          SE_FILE_OBJECT,
          DWORD(DACL_SECURITY_INFORMATION),
          nil,
          nil,
          &oldDacl,
          nil,
          &pSD
        )
      }
      guard getRes == ERROR_SUCCESS else { return false }
      defer { if let pSD { _ = LocalFree(pSD) } }

      var newDacl: PACL?
      let setRes = SetEntriesInAclW(1, &ea, oldDacl, &newDacl)
      guard setRes == ERROR_SUCCESS, let newDacl else { return false }
      defer { _ = LocalFree(newDacl) }

      let applyRes = path.withCString(encodedAs: UTF16.self) { p in
        SetNamedSecurityInfoW(
          UnsafeMutablePointer(mutating: p),
          SE_FILE_OBJECT,
          DWORD(DACL_SECURITY_INFORMATION),
          nil,
          nil,
          newDacl,
          nil
        )
      }
      return applyRes == ERROR_SUCCESS
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
      var entries = currentEnvironmentEntries()
      for (name, value) in environment {
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

    private final class OutputReader: @unchecked Sendable {
      private let handle: HANDLE
      private let onOutput: @Sendable (Data) -> Void
      private let lock = NSLock()
      private var finished = false

      init(handle: HANDLE, onOutput: @escaping @Sendable (Data) -> Void) {
        self.handle = handle
        self.onOutput = onOutput
      }

      func start() {
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
          onOutput(Data(bytes.prefix(Int(received))))
        }
        _ = CloseHandle(handle)
        lock.withLock { finished = true }
      }
    }
  }
#endif
