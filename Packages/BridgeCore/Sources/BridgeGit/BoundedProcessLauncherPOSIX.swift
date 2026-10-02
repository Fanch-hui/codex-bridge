import Foundation

#if canImport(Darwin)
  import Darwin
  private typealias SpawnFileActions = posix_spawn_file_actions_t?
  private typealias SpawnAttributes = posix_spawnattr_t?
  @_silgen_name("posix_spawn_file_actions_addfchdir_np")
  private func bridgeSpawnFileActionsAddFchdir(
    _ actions: UnsafeMutablePointer<posix_spawn_file_actions_t?>,
    _ descriptor: Int32
  ) -> Int32
#elseif canImport(Glibc)
  import Glibc
  private typealias SpawnFileActions = posix_spawn_file_actions_t
  private typealias SpawnAttributes = posix_spawnattr_t
  @_silgen_name("posix_spawn_file_actions_addfchdir_np")
  private func bridgeSpawnFileActionsAddFchdir(
    _ actions: UnsafeMutablePointer<posix_spawn_file_actions_t>,
    _ descriptor: Int32
  ) -> Int32
#endif

#if !os(Windows)
  enum BoundedProcessPlatformLauncher {
    static func spawn(_ configuration: BoundedProcessConfiguration) throws -> BoundedProcessChild {
      var outputPipe = try DescriptorPipe()
      defer { outputPipe.closeBoth() }
      var errorPipe = try DescriptorPipe()
      defer { errorPipe.closeBoth() }
      #if canImport(Darwin)
        var actions: SpawnFileActions = nil
        var attributes: SpawnAttributes = nil
      #else
        var actions = SpawnFileActions()
        var attributes = SpawnAttributes()
      #endif
      guard posix_spawn_file_actions_init(&actions) == 0 else {
        throw BoundedProcessError.launchFailed
      }
      guard posix_spawnattr_init(&attributes) == 0 else {
        posix_spawn_file_actions_destroy(&actions)
        throw BoundedProcessError.launchFailed
      }
      defer {
        posix_spawn_file_actions_destroy(&actions)
        posix_spawnattr_destroy(&attributes)
      }
      try Self.configureFileActions(
        &actions,
        currentDirectoryDescriptor: configuration.workingDirectory.descriptor,
        outputPipe: outputPipe,
        errorPipe: errorPipe
      )
      #if os(Linux)
        for descriptor in [
          outputPipe.readDescriptor, errorPipe.readDescriptor,
          outputPipe.writeDescriptor, errorPipe.writeDescriptor,
        ] {
          guard posix_spawn_file_actions_addclose(&actions, descriptor) == 0 else {
            throw BoundedProcessError.launchFailed
          }
        }
      #endif
      try Self.configureSpawnAttributes(&attributes)
      var pid: pid_t = 0
      let status = Self.spawn(
        pid: &pid,
        executable: configuration.executableURL.path,
        arguments: [configuration.executableURL.path] + configuration.arguments,
        environment: configuration.environment,
        actions: &actions,
        attributes: &attributes
      )
      guard status == 0 else { throw BoundedProcessError.launchFailed }
      outputPipe.closeWrite()
      errorPipe.closeWrite()
      return BoundedProcessChild(
        pid: pid,
        outputDescriptor: outputPipe.takeRead(),
        errorDescriptor: errorPipe.takeRead(),
        maximumStandardOutputBytes: configuration.maximumStandardOutputBytes,
        maximumStandardErrorBytes: configuration.maximumStandardErrorBytes
      )
    }

    private static func configureFileActions(
      _ actions: inout SpawnFileActions,
      currentDirectoryDescriptor: Int32,
      outputPipe: DescriptorPipe,
      errorPipe: DescriptorPipe
    ) throws {
      guard
        posix_spawn_file_actions_addopen(
          &actions,
          STDIN_FILENO,
          "/dev/null",
          O_RDONLY,
          0
        ) == 0,
        posix_spawn_file_actions_adddup2(
          &actions,
          outputPipe.writeDescriptor,
          STDOUT_FILENO
        ) == 0,
        posix_spawn_file_actions_adddup2(
          &actions,
          errorPipe.writeDescriptor,
          STDERR_FILENO
        ) == 0,
        bridgeSpawnFileActionsAddFchdir(&actions, currentDirectoryDescriptor) == 0
      else {
        throw BoundedProcessError.launchFailed
      }
    }

    private static func configureSpawnAttributes(
      _ attributes: inout SpawnAttributes
    ) throws {
      var defaults = sigset_t()
      sigemptyset(&defaults)
      for signal in [SIGTERM, SIGINT, SIGHUP, SIGQUIT, SIGPIPE] {
        sigaddset(&defaults, signal)
      }
      var mask = sigset_t()
      sigemptyset(&mask)
      #if canImport(Darwin)
        let flags = Int16(
          POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
        )
      #else
        let flags = Int16(POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)
      #endif
      guard posix_spawnattr_setsigdefault(&attributes, &defaults) == 0,
        posix_spawnattr_setsigmask(&attributes, &mask) == 0,
        posix_spawnattr_setflags(&attributes, flags) == 0
      else {
        throw BoundedProcessError.launchFailed
      }
    }

    private static func spawn(
      pid: inout pid_t,
      executable: String,
      arguments: [String],
      environment: [String],
      actions: inout SpawnFileActions,
      attributes: inout SpawnAttributes
    ) -> Int32 {
      let ownedArguments = arguments.compactMap { strdup($0) }
      guard ownedArguments.count == arguments.count else { return ENOMEM }
      defer {
        for argument in ownedArguments { free(argument) }
      }
      let ownedEnvironment = environment.compactMap { strdup($0) }
      guard ownedEnvironment.count == environment.count else { return ENOMEM }
      defer {
        for value in ownedEnvironment { free(value) }
      }

      var argv: [UnsafeMutablePointer<CChar>?] = ownedArguments + [nil]
      var envp: [UnsafeMutablePointer<CChar>?] = ownedEnvironment + [nil]
      return argv.withUnsafeMutableBufferPointer { argvBuffer in
        envp.withUnsafeMutableBufferPointer { environmentBuffer in
          posix_spawn(
            &pid,
            executable,
            &actions,
            &attributes,
            argvBuffer.baseAddress,
            environmentBuffer.baseAddress
          )
        }
      }
    }
  }

  #if !os(Windows)
    private struct DescriptorPipe {
      private(set) var readDescriptor: Int32
      private(set) var writeDescriptor: Int32

      init() throws {
        var descriptors: [Int32] = [0, 0]
        guard pipe(&descriptors) == 0 else { throw BoundedProcessError.launchFailed }
        readDescriptor = descriptors[0]
        writeDescriptor = descriptors[1]
        guard Self.setCloseOnExec(readDescriptor), Self.setCloseOnExec(writeDescriptor),
          Self.setNonBlocking(readDescriptor)
        else {
          POSIXSystem.close(readDescriptor)
          POSIXSystem.close(writeDescriptor)
          throw BoundedProcessError.launchFailed
        }
      }

      mutating func takeRead() -> Int32 {
        let descriptor = readDescriptor
        readDescriptor = -1
        return descriptor
      }

      mutating func closeWrite() {
        guard writeDescriptor >= 0 else { return }
        POSIXSystem.close(writeDescriptor)
        writeDescriptor = -1
      }

      mutating func closeBoth() {
        if readDescriptor >= 0 { POSIXSystem.close(readDescriptor) }
        if writeDescriptor >= 0 { POSIXSystem.close(writeDescriptor) }
        readDescriptor = -1
        writeDescriptor = -1
      }

      private static func setCloseOnExec(_ descriptor: Int32) -> Bool {
        fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0
      }

      private static func setNonBlocking(_ descriptor: Int32) -> Bool {
        let flags = fcntl(descriptor, F_GETFL)
        return flags >= 0 && fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0
      }
    }
  #endif
#endif
