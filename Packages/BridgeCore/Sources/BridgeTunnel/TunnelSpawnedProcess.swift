import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

#if !os(Windows)
  final class TunnelSpawnedProcess: @unchecked Sendable {
    let pid: pid_t
    let stdout: RedactedOutputBuffer
    let stderr: RedactedOutputBuffer
    private let stdoutReader: TunnelDescriptorReader
    private let stderrReader: TunnelDescriptorReader
    private let lock = NSLock()
    private var exit: TunnelChildExit?
    private var terminationClaimed = false

    init(
      pid: pid_t,
      stdout: RedactedOutputBuffer,
      stderr: RedactedOutputBuffer,
      stdoutDescriptor: Int32,
      stderrDescriptor: Int32
    ) {
      self.pid = pid
      self.stdout = stdout
      self.stderr = stderr
      stdoutReader = TunnelDescriptorReader(descriptor: stdoutDescriptor, buffer: stdout)
      stderrReader = TunnelDescriptorReader(descriptor: stderrDescriptor, buffer: stderr)
      stdoutReader.start()
      stderrReader.start()
    }

    deinit {
      lock.withLock {
        guard resolveExitLocked() == nil else { return }
        _ = kill(pid, SIGKILL)
        var status: Int32 = 0
        var result: pid_t = -1
        repeat {
          result = waitpid(pid, &status, 0)
        } while result < 0 && errno == EINTR
        guard result == pid else { return }
        exit = TunnelChildExit(code: Self.exitCode(status))
        stdoutReader.finish()
        stderrReader.finish()
      }
    }

    func pollExit() -> TunnelChildExit? {
      lock.withLock {
        resolveExitLocked()
      }
    }

    func beginTermination() -> Bool {
      lock.withLock {
        guard resolveExitLocked() == nil, !terminationClaimed else { return false }
        terminationClaimed = true
        return kill(pid, SIGTERM) == 0 || errno == ESRCH
      }
    }

    func escalateTermination() {
      lock.withLock {
        guard resolveExitLocked() == nil else { return }
        _ = kill(pid, SIGKILL)
      }
    }

    private func resolveExitLocked() -> TunnelChildExit? {
      if let exit { return exit }
      var status: Int32 = 0
      let result = waitpid(pid, &status, WNOHANG)
      if result < 0, errno == ECHILD {
        let resolved = TunnelChildExit(code: 255)
        exit = resolved
        stdoutReader.finish()
        stderrReader.finish()
        return resolved
      }
      guard result == pid else { return nil }
      let resolved = TunnelChildExit(code: Self.exitCode(status))
      exit = resolved
      stdoutReader.finish()
      stderrReader.finish()
      return resolved
    }

    private static func exitCode(_ status: Int32) -> Int32 {
      let signal = status & 0x7f
      if signal == 0 { return (status >> 8) & 0xff }
      if signal != 0x7f { return 128 + signal }
      return status
    }
  }
#endif
