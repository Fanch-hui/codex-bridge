#if os(Windows)
  import WinSDK

  final class ManagedWindowsProcessJob {
    private let handle: HANDLE

    init() throws {
      guard let job = CreateJobObjectW(nil, nil) else {
        throw ManagedProcessError.processLaunchFailed(Int32(GetLastError()))
      }
      var limits = JOBOBJECT_EXTENDED_LIMIT_INFORMATION()
      limits.BasicLimitInformation.LimitFlags = DWORD(JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE)
      guard
        SetInformationJobObject(
          job, JobObjectExtendedLimitInformation, &limits,
          DWORD(MemoryLayout<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>.size)
        )
      else {
        let error = GetLastError()
        _ = CloseHandle(job)
        throw ManagedProcessError.processLaunchFailed(Int32(error))
      }
      handle = job
    }

    deinit { _ = CloseHandle(handle) }

    func assignAndResume(process: HANDLE, thread: HANDLE?) throws {
      guard AssignProcessToJobObject(handle, process), ResumeThread(thread) != DWORD.max else {
        throw ManagedProcessError.processLaunchFailed(Int32(GetLastError()))
      }
    }

    func terminate() -> Bool {
      TerminateJobObject(handle, 1)
    }
  }
#endif
