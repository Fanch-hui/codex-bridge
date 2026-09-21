import Foundation

#if os(Windows)
  import Crypto
  import WinSDK
#elseif canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

/// Serializes recovery and execution for all service copies sharing one data root.
final class ServiceDataRootLock: @unchecked Sendable {
  enum Failure: Error { case alreadyRunning, unavailable }
  #if os(Windows)
    private let handle: HANDLE
  #else
    private let descriptor: Int32
  #endif

  init(rootURL: URL) throws {
    let root = try ServiceDataPaths.prepare(at: rootURL).rootURL.resolvingSymlinksInPath()
    #if os(Windows)
      let identity = root.path.replacingOccurrences(of: "/", with: "\\").lowercased()
      let digest = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }
        .joined()
      let security = try WindowsNamedPipeSecurity()
      var attributes = security.attributes
      let name = "Global\\org.codexbridge.data.\(digest)"
      let (created, error) = name.withCString(encodedAs: UTF16.self) { pointer in
        SetLastError(0)
        let handle = CreateMutexW(&attributes, false, pointer)
        return (handle, GetLastError())
      }
      guard let created else { throw Failure.unavailable }
      guard error != ERROR_ALREADY_EXISTS else {
        _ = CloseHandle(created)
        throw Failure.alreadyRunning
      }
      handle = created
    #else
      let path = root.appendingPathComponent("service.lock").path
      let opened = open(path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
      guard opened >= 0 else { throw Failure.unavailable }
      guard flock(opened, LOCK_EX | LOCK_NB) == 0 else {
        close(opened)
        throw Failure.alreadyRunning
      }
      descriptor = opened
    #endif
  }

  deinit {
    #if os(Windows)
      _ = CloseHandle(handle)
    #else
      close(descriptor)
    #endif
  }
}
