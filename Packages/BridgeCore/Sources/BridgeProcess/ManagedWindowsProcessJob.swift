#if os(Windows)
  import Foundation
  import WinSDK

  final class ManagedWindowsProcessJob {
    private let handle: HANDLE

    init(name: String? = nil) throws {
      let creation: (HANDLE?, DWORD)
      if let name {
        creation = name.withCString(encodedAs: UTF16.self) {
          let handle = CreateJobObjectW(nil, $0)
          return (handle, GetLastError())
        }
      } else {
        let handle = CreateJobObjectW(nil, nil)
        creation = (handle, GetLastError())
      }
      guard let job = creation.0 else {
        throw ManagedProcessError.processLaunchFailed(Int32(creation.1))
      }
      if name != nil, creation.1 == DWORD(ERROR_ALREADY_EXISTS) {
        _ = CloseHandle(job)
        throw ManagedProcessError.processLaunchFailed(Int32(ERROR_ALREADY_EXISTS))
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

    private init(handle: HANDLE) {
      self.handle = handle
    }

    static func recover(name: String) -> Bool {
      let result: (HANDLE?, DWORD) = name.withCString(encodedAs: UTF16.self) {
        let handle = OpenJobObjectW(DWORD(JOB_OBJECT_QUERY | JOB_OBJECT_TERMINATE), false, $0)
        return (handle, GetLastError())
      }
      guard let handle = result.0 else { return result.1 == DWORD(ERROR_FILE_NOT_FOUND) }
      let job = ManagedWindowsProcessJob(handle: handle)
      guard job.terminate() else { return job.isEmpty() }
      let deadline = ContinuousClock.now.advanced(by: .seconds(6))
      repeat {
        if job.isEmpty() { return true }
        Thread.sleep(forTimeInterval: 0.01)
      } while ContinuousClock.now < deadline
      return false
    }

    func assignAndResume(process: HANDLE, thread: HANDLE?) throws {
      guard AssignProcessToJobObject(handle, process), ResumeThread(thread) != DWORD.max else {
        throw ManagedProcessError.processLaunchFailed(Int32(GetLastError()))
      }
    }

    func terminate() -> Bool {
      TerminateJobObject(handle, 1)
    }

    func isEmpty() -> Bool {
      var accounting = JOBOBJECT_BASIC_ACCOUNTING_INFORMATION()
      guard
        QueryInformationJobObject(
          handle, JobObjectBasicAccountingInformation, &accounting,
          DWORD(MemoryLayout<JOBOBJECT_BASIC_ACCOUNTING_INFORMATION>.size), nil
        )
      else { return false }
      return accounting.ActiveProcesses == 0
    }
  }
#endif
