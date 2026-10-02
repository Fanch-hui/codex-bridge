#if os(Linux)
  import BridgeIPC
  import Foundation
  import Glibc

  final class BridgeServiceSocketListener: ServiceRequestListener, @unchecked Sendable {
    private let descriptor: Int32
    private let path: String
    private let composition: ServiceComposition
    private let lock = NSLock()
    private var running = false
    private var invalidated = false
    private var connections: [LinuxServiceConnection] = []

    init(composition: ServiceComposition, path: String = LinuxServiceEndpoint.socketPath) throws {
      self.composition = composition
      self.path = path
      try LinuxServiceEndpoint.prepareDirectory(
        URL(fileURLWithPath: path).deletingLastPathComponent())
      let descriptor = try LinuxSocketChannel.createDescriptor()
      do {
        try Self.removeStaleSocket(path)
        try LinuxSocketChannel.withAddress(path: path) { address, length in
          guard bind(descriptor, address, length) == 0 else {
            throw LinuxSocketError.system(errno)
          }
        }
        guard chmod(path, 0o600) == 0, listen(descriptor, 16) == 0,
          fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0
        else { throw LinuxSocketError.system(errno) }
      } catch {
        _ = Glibc.close(descriptor)
        throw error
      }
      self.descriptor = descriptor
    }

    deinit { invalidate() }

    func resume() {
      let start = lock.withLock {
        guard !running, !invalidated else { return false }
        running = true
        return true
      }
      guard start else { return }
      let thread = Thread { [weak self] in self?.acceptLoop() }
      thread.name = "codex-bridge.socket-listener"
      thread.start()
    }

    func invalidate() {
      let active = lock.withLock { () -> [LinuxServiceConnection] in
        guard !invalidated else { return [] }
        invalidated = true
        running = false
        _ = Glibc.close(descriptor)
        _ = unlink(path)
        let active = connections
        connections.removeAll()
        return active
      }
      for connection in active { connection.close() }
    }

    private func acceptLoop() {
      while lock.withLock({ running }) {
        var event = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        guard poll(&event, 1, 200) > 0 else { continue }
        let accepted = lock.withLock {
          running ? accept(descriptor, nil, nil) : -1
        }
        guard accepted >= 0 else { continue }
        _ = fcntl(accepted, F_SETFD, FD_CLOEXEC)
        guard
          LinuxSocketIdentity.accepts(
            descriptor: accepted,
            executableNames: ["codex-bridge-linux-app", "codex-bridge-service"]
          )
        else {
          _ = Glibc.close(accepted)
          continue
        }
        let connection = LinuxServiceConnection(descriptor: accepted, composition: composition)
        let attached = lock.withLock {
          guard running else { return false }
          connections.append(connection)
          return true
        }
        guard attached else {
          connection.close()
          return
        }
        connection.start { [weak self] connection in
          self?.remove(connection)
        }
      }
    }

    private func remove(_ connection: LinuxServiceConnection) {
      lock.withLock { connections.removeAll { $0 === connection } }
    }

    private static func removeStaleSocket(_ path: String) throws {
      var metadata = stat()
      guard lstat(path, &metadata) == 0 else {
        if errno == ENOENT { return }
        throw LinuxSocketError.system(errno)
      }
      guard metadata.st_uid == getuid(), metadata.st_mode & S_IFMT == S_IFSOCK else {
        throw LinuxSocketError.invalidIdentity
      }
      do {
        let active = try LinuxSocketChannel.connect(path: path)
        active.close()
        throw LinuxSocketError.system(EADDRINUSE)
      } catch LinuxSocketError.system(let code) where code == ECONNREFUSED {
      }
      guard unlink(path) == 0 else { throw LinuxSocketError.system(errno) }
    }
  }
#endif
