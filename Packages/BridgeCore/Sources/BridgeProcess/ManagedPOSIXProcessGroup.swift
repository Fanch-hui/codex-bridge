#if !os(Windows)
  import Foundation
  #if canImport(Darwin)
    import Darwin
  #else
    import Glibc
  #endif

  final class ManagedPOSIXProcessGroup: @unchecked Sendable {
    private let pid: Int32
    private let identity: ManagedProcessIdentity?
    private let lock = NSLock()
    private var owned = true

    init(pid: Int32, identity: ManagedProcessIdentity?) {
      self.pid = pid
      self.identity = identity
    }

    func signal(_ signal: Int32) {
      lock.lock()
      defer { lock.unlock() }
      guard existsLocked() else { return }
      if kill(-pid, signal) != 0, errno == ESRCH { owned = false }
    }

    var exists: Bool {
      lock.lock()
      defer { lock.unlock() }
      return existsLocked()
    }

    private func existsLocked() -> Bool {
      guard owned else { return false }
      // A surviving descendant retains the group after its leader is reaped.
      // A new leader with this PID belongs to a different spawn.
      if getpgid(pid) >= 0, ManagedStdioProcess.identity(of: pid) != identity {
        owned = false
        return false
      }
      if kill(-pid, 0) == 0 || errno == EPERM { return true }
      owned = false
      return false
    }
  }
#endif
