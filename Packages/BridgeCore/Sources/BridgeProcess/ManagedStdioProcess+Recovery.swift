import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

extension ManagedStdioProcess {
  static func isRecordedProcessTreeStopped(
    identity: ManagedProcessIdentity, groupName: String
  ) -> Bool {
    guard identity.pid > 1, identity.processGroupID == identity.pid else { return false }
    #if os(Windows)
      return ManagedWindowsProcessJob.isStopped(name: groupName)
    #else
      return recoveryState(identity) == .absent
    #endif
  }

  /// Stops a recorded host only when the operating system confirms its identity.
  public static func recoverProcessTree(
    identity: ManagedProcessIdentity, groupName: String
  ) -> Bool {
    guard identity.pid > 1, identity.processGroupID == identity.pid else { return false }
    #if os(Windows)
      return ManagedWindowsProcessJob.recover(name: groupName)
    #else
      // A leader that has just exited can be briefly unverifiable until it is reaped; wait
      // for that to settle without signalling a process this launch might not own.
      var state = recoveryState(identity)
      let settleDeadline = ContinuousClock.now.advanced(by: .seconds(5))
      while state == .unverified, ContinuousClock.now < settleDeadline {
        Thread.sleep(forTimeInterval: 0.01)
        state = recoveryState(identity)
      }
      switch state {
      case .absent: return true
      case .unverified: return false
      case .owned: break
      }
      let group = ManagedPOSIXProcessGroup(pid: identity.pid, identity: identity)
      group.signal(SIGTERM)
      let termDeadline = ContinuousClock.now.advanced(by: .seconds(1))
      while ContinuousClock.now < termDeadline {
        if recoveryState(identity) == .absent { return true }
        Thread.sleep(forTimeInterval: 0.01)
      }
      let killDeadline = ContinuousClock.now.advanced(by: .seconds(5))
      var sentKill = false
      repeat {
        switch recoveryState(identity) {
        case .absent: return true
        case .owned where !sentKill:
          group.signal(SIGKILL)
          sentKill = true
        case .owned, .unverified: break
        }
        Thread.sleep(forTimeInterval: 0.01)
      } while ContinuousClock.now < killDeadline
      return false
    #endif
  }

  #if !os(Windows)
    private enum RecoveryState {
      case absent, owned, unverified
    }

    private static func recoveryState(_ identity: ManagedProcessIdentity) -> RecoveryState {
      if kill(-identity.processGroupID, 0) != 0 {
        if errno == ESRCH { return .absent }
        if errno != EPERM { return .unverified }
      }
      if matchesCurrentProcess(identity) { return .owned }
      // The leader exited while members of its group remain. A process group ID is not reused
      // while the group exists, so those members still belong to this launch.
      if kill(identity.pid, 0) != 0, errno == ESRCH { return .owned }
      return .unverified
    }
  #endif
}
