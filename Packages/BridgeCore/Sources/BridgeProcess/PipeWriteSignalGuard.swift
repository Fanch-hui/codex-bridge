import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

#if !os(Windows)
  /// Scoped to a synchronous pipe write; never changes the process-wide SIGPIPE disposition.
  package struct PipeWriteSignalGuard {
    #if os(Linux)
      private var previous: sigset_t
      private var blocked: sigset_t
      private let alreadyPending: Bool
    #endif

    package init(descriptor: Int32) throws {
      #if canImport(Darwin)
        guard fcntl(descriptor, F_SETNOSIGPIPE, 1) == 0 else {
          throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
      #else
        var blocked = sigset_t()
        var previous = sigset_t()
        sigemptyset(&blocked)
        sigaddset(&blocked, SIGPIPE)
        let result = pthread_sigmask(SIG_BLOCK, &blocked, &previous)
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EIO) }
        var pending = sigset_t()
        sigpending(&pending)
        self.alreadyPending = sigismember(&pending, SIGPIPE) == 1
        self.blocked = blocked
        self.previous = previous
      #endif
    }

    package mutating func restore() {
      #if os(Linux)
        if !alreadyPending {
          var timeout = timespec(tv_sec: 0, tv_nsec: 0)
          while sigtimedwait(&blocked, nil, &timeout) < 0, errno == EINTR {}
        }
        pthread_sigmask(SIG_SETMASK, &previous, nil)
      #endif
    }
  }
#endif
