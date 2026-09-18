#if os(Windows)
  import Foundation
  import WinSDK

  extension WindowsSecureFile {
    /// Rejects reparse points on every intermediate component, mirroring the
    /// POSIX O_NOFOLLOW traversal guarantee.
    static func validateComponents(
      rootPath: String,
      components: [String],
      includingFinal: Bool
    ) throws {
      guard !components.isEmpty || !rootPath.isEmpty else {
        throw PathSecurityError.invalidRelativePath("empty root")
      }
      var current = rootPath
      let componentsToValidate = includingFinal ? components : Array(components.dropLast())
      for (index, component) in componentsToValidate.enumerated() {
        current = current + "\\" + component
        let handle = current.withCString(encodedAs: UTF16.self) { wide in
          CreateFileW(
            wide,
            DWORD(FILE_READ_ATTRIBUTES),
            DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE),
            nil,
            DWORD(OPEN_EXISTING),
            DWORD(FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT),
            nil
          )
        }
        guard let handle, handle != INVALID_HANDLE_VALUE else {
          throw WindowsSecureFileError.openFailed(Int32(GetLastError()))
        }
        defer { WindowsSecureFile.close(handle) }
        let metadata = try WindowsSecureFile.metadata(of: handle)
        guard !metadata.isReparsePoint else {
          throw PathSecurityError.pathEscapeBlocked
        }
        if index < componentsToValidate.count - 1 || !includingFinal {
          guard metadata.isDirectory else { throw PathSecurityError.pathEscapeBlocked }
        }
      }
    }

    /// Checks the parent chain and optionally creates missing directories.
    /// The leaf is deliberately excluded so CREATE_NEW can establish it
    /// atomically without a preflight existence check.
    static func ensureParentDirectories(
      root: RegisteredRoot,
      components: [String],
      createMissing: Bool
    ) throws {
      let parents = Array(components.dropLast())
      guard !components.isEmpty else {
        throw PathSecurityError.invalidRelativePath("empty path")
      }
      var current = root.canonicalPath
      for component in parents {
        current = current + "\\" + component
        let attributes = current.withCString(encodedAs: UTF16.self) { wide in
          GetFileAttributesW(wide)
        }
        if attributes == INVALID_FILE_ATTRIBUTES {
          let error = Int32(GetLastError())
          let missing =
            error == Int32(ERROR_FILE_NOT_FOUND)
            || error == Int32(ERROR_PATH_NOT_FOUND)
          if missing, !createMissing {
            throw PathSecurityError.pathDoesNotExist
          }
          guard createMissing, missing else {
            throw WindowsSecureFileError.openFailed(error)
          }
          let created = current.withCString(encodedAs: UTF16.self) { wide in
            CreateDirectoryW(wide, nil)
          }
          if !created {
            let error = Int32(GetLastError())
            guard error == Int32(ERROR_ALREADY_EXISTS) else {
              throw WindowsSecureFileError.openFailed(error)
            }
          }
        }
        try validateDirectoryPath(current)
      }
    }

    private static func validateDirectoryPath(_ path: String) throws {
      let handle = path.withCString(encodedAs: UTF16.self) { wide in
        CreateFileW(
          wide,
          DWORD(FILE_READ_ATTRIBUTES),
          DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE),
          nil,
          DWORD(OPEN_EXISTING),
          DWORD(FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT),
          nil
        )
      }
      guard let handle, handle != INVALID_HANDLE_VALUE else {
        throw WindowsSecureFileError.openFailed(Int32(GetLastError()))
      }
      defer { WindowsSecureFile.close(handle) }
      let metadata = try WindowsSecureFile.metadata(of: handle)
      guard metadata.isDirectory, !metadata.isReparsePoint else {
        throw PathSecurityError.pathEscapeBlocked
      }
    }
  }
#endif
