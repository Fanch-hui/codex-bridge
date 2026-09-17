#if os(Windows)
  import BridgeSecurity
  import Foundation
  import WinSDK

  /// Handle-based secure run directory for the Windows Tunnel boundary.
  ///
  /// Windows has no `openat`; the root identity is pinned by device/index and
  /// every path traversal rejects reparse points through `WindowsSecureFile`,
  /// mirroring the POSIX fd-validated semantics (see docs/WINDOWS_PORT.md).
  package final class TunnelDirectoryHandle: @unchecked Sendable {
    package let path: String
    private let device: UInt64
    private let inode: UInt64

    package init(existingRoot: URL) throws {
      path = WindowsTunnelPathRules.normalize(existingRoot.path)
      let (handle, metadata) = try Self.openRoot(path, access: DWORD(FILE_READ_ATTRIBUTES))
      defer { WindowsSecureFile.close(handle) }
      guard metadata.isDirectory else { throw TunnelManagerError.launchFailed }
      device = metadata.identity.device
      inode = metadata.identity.inode
      guard matchesPath() else { throw TunnelManagerError.launchFailed }
    }

    package init(creating name: String, in parent: TunnelDirectoryHandle) throws {
      guard WindowsTunnelPathRules.isSafeEntryName(name), parent.matchesPath() else {
        throw TunnelManagerError.launchFailed
      }
      path = WindowsTunnelPathRules.join(parent.path, name)
      let created = path.withCString(encodedAs: UTF16.self) { CreateDirectoryW($0, nil) }
      guard created else { throw TunnelManagerError.launchFailed }
      do {
        let (handle, metadata) = try Self.openRoot(path, access: DWORD(FILE_READ_ATTRIBUTES))
        defer { WindowsSecureFile.close(handle) }
        guard metadata.isDirectory else { throw TunnelManagerError.launchFailed }
        device = metadata.identity.device
        inode = metadata.identity.inode
      } catch {
        _ = path.withCString(encodedAs: UTF16.self) { RemoveDirectoryW($0) }
        throw TunnelManagerError.launchFailed
      }
    }

    package func matchesPath() -> Bool {
      guard
        let (handle, metadata) = try? Self.openRoot(path, access: DWORD(FILE_READ_ATTRIBUTES))
      else { return false }
      defer { WindowsSecureFile.close(handle) }
      return metadata.isDirectory
        && metadata.identity.device == device
        && metadata.identity.inode == inode
    }

    package func contains(name: String, directory: TunnelDirectoryHandle) -> Bool {
      guard WindowsTunnelPathRules.isSafeEntryName(name), matchesPath(), directory.matchesPath()
      else {
        return false
      }
      guard
        let (handle, metadata) = try? WindowsSecureFile.openResolving(
          rootPath: path,
          components: [name],
          desiredAccess: DWORD(FILE_READ_ATTRIBUTES),
          creationDisposition: DWORD(OPEN_EXISTING),
          finalIsDirectory: true
        )
      else { return false }
      defer { WindowsSecureFile.close(handle) }
      return metadata.identity.device == directory.device
        && metadata.identity.inode == directory.inode
    }

    package func createDirectory(name: String) throws {
      guard WindowsTunnelPathRules.isSafeEntryName(name), matchesPath() else {
        throw TunnelManagerError.launchFailed
      }
      let target = WindowsTunnelPathRules.join(path, name)
      let created = target.withCString(encodedAs: UTF16.self) { CreateDirectoryW($0, nil) }
      guard created else { throw TunnelManagerError.launchFailed }
    }

    package func readRegularFile(name: String, maximumBytes: Int) throws -> Data {
      guard WindowsTunnelPathRules.isSafeEntryName(name), maximumBytes > 0, matchesPath() else {
        throw TunnelHealthError.invalidURLFile
      }
      let (handle, metadata) = try openFile(name: name)
      defer { WindowsSecureFile.close(handle) }
      guard metadata.isRegularFile, metadata.size > 0, metadata.size <= maximumBytes else {
        throw TunnelHealthError.invalidURLFile
      }
      do {
        return try WindowsSecureFile.readFile(handle, maximumBytes: maximumBytes)
      } catch {
        throw TunnelHealthError.unavailable
      }
    }

    package func removeEntry(name: String, directory: Bool = false) throws {
      guard WindowsTunnelPathRules.isSafeEntryName(name), matchesPath() else {
        throw TunnelManagerError.cleanupFailed
      }
      let target = WindowsTunnelPathRules.join(path, name)
      let removed = target.withCString(encodedAs: UTF16.self) { wide in
        directory ? RemoveDirectoryW(wide) : DeleteFileW(wide)
      }
      if !removed {
        let error = GetLastError()
        if error != ERROR_FILE_NOT_FOUND, error != ERROR_PATH_NOT_FOUND {
          throw TunnelManagerError.cleanupFailed
        }
      }
    }

    private func openFile(name: String) throws -> (HANDLE, WindowsSecureFile.Metadata) {
      do {
        return try WindowsSecureFile.openResolving(
          rootPath: path,
          components: [name],
          desiredAccess: DWORD(GENERIC_READ),
          creationDisposition: DWORD(OPEN_EXISTING),
          finalIsDirectory: false
        )
      } catch {
        throw TunnelHealthError.unavailable
      }
    }

    private static func openRoot(
      _ path: String,
      access: UInt32
    ) throws -> (HANDLE, WindowsSecureFile.Metadata) {
      do {
        return try WindowsSecureFile.openResolving(
          rootPath: path,
          components: [],
          desiredAccess: access,
          creationDisposition: DWORD(OPEN_EXISTING),
          finalIsDirectory: true
        )
      } catch {
        throw TunnelManagerError.launchFailed
      }
    }
  }
#endif
