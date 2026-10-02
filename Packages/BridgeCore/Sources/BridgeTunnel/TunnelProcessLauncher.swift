import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

struct TunnelChildExit: Equatable, Sendable {
  let code: Int32
}

#if !os(Windows)
  #if os(Linux)
    private typealias TunnelSpawnActions = posix_spawn_file_actions_t
    private typealias TunnelSpawnAttributes = posix_spawnattr_t
  #else
    private typealias TunnelSpawnActions = posix_spawn_file_actions_t?
    private typealias TunnelSpawnAttributes = posix_spawnattr_t?
  #endif

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
      let secretPipe = try TunnelDescriptorPipe()
      let urlPipe = try TunnelDescriptorPipe()
      let stdoutPipe = try TunnelDescriptorPipe()
      let stderrPipe = try TunnelDescriptorPipe()
      #if os(Linux)
        var actions = TunnelSpawnActions()
        var attributes = TunnelSpawnAttributes()
      #else
        var actions: TunnelSpawnActions = nil
        var attributes: TunnelSpawnAttributes = nil
      #endif
      guard posix_spawn_file_actions_init(&actions) == 0 else {
        throw TunnelManagerError.launchFailed
      }
      guard posix_spawnattr_init(&attributes) == 0 else {
        posix_spawn_file_actions_destroy(&actions)
        throw TunnelManagerError.launchFailed
      }
      defer {
        posix_spawn_file_actions_destroy(&actions)
        posix_spawnattr_destroy(&attributes)
      }
      try configureActions(
        &actions,
        secretRead: secretPipe.readDescriptor,
        urlRead: urlPipe.readDescriptor,
        stdoutWrite: stdoutPipe.writeDescriptor,
        stderrWrite: stderrPipe.writeDescriptor
      )
      try configureAttributes(&attributes)
      var pid: pid_t = 0
      let status = spawn(
        &pid,
        executable: verifiedHelper.executable.path,
        arguments: [verifiedHelper.executable.path] + arguments,
        actions: &actions,
        attributes: &attributes,
        runtimeDirectory: runtimeDirectory
      )
      guard status == 0 else { throw TunnelManagerError.launchFailed }
      secretPipe.closeRead()
      urlPipe.closeRead()
      stdoutPipe.closeWrite()
      stderrPipe.closeWrite()
      do {
        try helperVerifier.verifyRunning(
          processID: pid,
          expectedIdentity: verifiedHelper.codeIdentity
        )
        #if canImport(Darwin)
          guard kill(pid, SIGCONT) == 0 else {
            throw TunnelManagerError.launchFailed
          }
        #endif
        try writeAndClose(runtimeKey, to: secretPipe)
        try writeAndClose(localMCPHeaderSecret, to: urlPipe)
      } catch {
        secretPipe.closeWrite()
        urlPipe.closeWrite()
        killAndReap(pid)
        throw error
      }
      let stdout = RedactedOutputBuffer(limit: outputLimit, sensitiveValues: sensitiveValues)
      let stderr = RedactedOutputBuffer(limit: outputLimit, sensitiveValues: sensitiveValues)
      return TunnelSpawnedProcess(
        pid: pid,
        stdout: stdout,
        stderr: stderr,
        stdoutDescriptor: stdoutPipe.takeRead(),
        stderrDescriptor: stderrPipe.takeRead()
      )
    }

    private func configureAttributes(_ attributes: inout TunnelSpawnAttributes) throws {
      var defaults = sigset_t()
      sigemptyset(&defaults)
      sigaddset(&defaults, SIGTERM)
      sigaddset(&defaults, SIGINT)
      sigaddset(&defaults, SIGHUP)
      sigaddset(&defaults, SIGQUIT)
      var mask = sigset_t()
      sigemptyset(&mask)
      guard posix_spawnattr_setsigdefault(&attributes, &defaults) == 0,
        posix_spawnattr_setsigmask(&attributes, &mask) == 0
      else {
        throw TunnelManagerError.launchFailed
      }
      #if os(Linux)
        let flags = Int16(POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)
      #else
        let flags = Int16(
          POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
            | POSIX_SPAWN_START_SUSPENDED
        )
      #endif
      guard posix_spawnattr_setflags(&attributes, flags) == 0 else {
        throw TunnelManagerError.launchFailed
      }
    }

    private func configureActions(
      _ actions: inout TunnelSpawnActions,
      secretRead: Int32,
      urlRead: Int32,
      stdoutWrite: Int32,
      stderrWrite: Int32
    ) throws {
      guard
        posix_spawn_file_actions_addopen(
          &actions,
          STDIN_FILENO,
          "/dev/null",
          O_RDONLY,
          0
        ) == 0
      else {
        throw TunnelManagerError.launchFailed
      }
      let mappings: [(Int32, Int32)] = [
        (secretRead, 3), (urlRead, 4), (stdoutWrite, STDOUT_FILENO),
        (stderrWrite, STDERR_FILENO),
      ]
      for mapping in mappings {
        guard posix_spawn_file_actions_adddup2(&actions, mapping.0, mapping.1) == 0 else {
          throw TunnelManagerError.launchFailed
        }
      }
    }

    private func spawn(
      _ pid: inout pid_t,
      executable: String,
      arguments: [String],
      actions: inout TunnelSpawnActions,
      attributes: inout TunnelSpawnAttributes,
      runtimeDirectory: URL
    ) -> Int32 {
      let ownedArguments = arguments.compactMap { strdup($0) }
      guard ownedArguments.count == arguments.count else { return ENOMEM }
      defer {
        for argument in ownedArguments { free(argument) }
      }
      var argv = ownedArguments + [nil]
      let runtimePath = runtimeDirectory.standardizedFileURL.path
      let environmentStrings: [String] = [
        "TMPDIR=\(runtimePath)",
        "CODEX_HOME=\(runtimePath)/codex-home",
      ]
      let ownedEnvironment: [UnsafeMutablePointer<CChar>] = environmentStrings.compactMap {
        strdup($0)
      }
      guard ownedEnvironment.count == environmentStrings.count else { return ENOMEM }
      defer {
        for value in ownedEnvironment { free(value) }
      }
      var environment: [UnsafeMutablePointer<CChar>?] = ownedEnvironment + [nil]
      return argv.withUnsafeMutableBufferPointer { argvBuffer in
        environment.withUnsafeMutableBufferPointer { environmentBuffer in
          posix_spawn(
            &pid,
            executable,
            &actions,
            &attributes,
            argvBuffer.baseAddress!,
            environmentBuffer.baseAddress!
          )
        }
      }
    }

    private func writeAndClose(_ data: Data, to pipe: TunnelDescriptorPipe) throws {
      let descriptor = pipe.writeDescriptor
      #if canImport(Darwin)
        _ = fcntl(descriptor, F_SETNOSIGPIPE, 1)
      #else
        var blocked = sigset_t()
        var previous = sigset_t()
        sigemptyset(&blocked)
        sigaddset(&blocked, SIGPIPE)
        pthread_sigmask(SIG_BLOCK, &blocked, &previous)
        defer {
          var timeout = timespec(tv_sec: 0, tv_nsec: 0)
          _ = sigtimedwait(&blocked, nil, &timeout)
          pthread_sigmask(SIG_SETMASK, &previous, nil)
        }
      #endif
      try data.withUnsafeBytes { bytes in
        guard let baseAddress = bytes.baseAddress else { return }
        var written = 0
        while written < bytes.count {
          #if os(Linux)
            let count = Glibc.write(
              descriptor, baseAddress.advanced(by: written), bytes.count - written)
          #else
            let count = Darwin.write(
              descriptor, baseAddress.advanced(by: written), bytes.count - written)
          #endif
          if count < 0, errno == EINTR { continue }
          guard count > 0 else { throw TunnelManagerError.launchFailed }
          written += count
        }
      }
      pipe.closeWrite()
    }

    private func killAndReap(_ pid: pid_t) {
      _ = kill(pid, SIGKILL)
      var status: Int32 = 0
      while waitpid(pid, &status, 0) < 0, errno == EINTR {}
    }
  }

#endif
