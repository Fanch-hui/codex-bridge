#if os(Windows)
  import Foundation
  import WinSDK

  #if os(Windows)
    final class PatchStoreLockHandle: @unchecked Sendable {
      let raw: HANDLE

      init(_ raw: HANDLE) {
        self.raw = raw
      }

      deinit {
        if raw != INVALID_HANDLE_VALUE { _ = CloseHandle(raw) }
      }
    }

    /// WinSDK primitives backing GitPatchStore on Windows; the POSIX code paths
    /// keep using descriptor-based calls.
    enum PatchStoreFile {
      static func openForReading(_ path: String) -> HANDLE {
        path.withCString(encodedAs: UTF16.self) {
          CreateFileW(
            $0,
            DWORD(GENERIC_READ),
            DWORD(FILE_SHARE_READ),
            nil,
            DWORD(OPEN_EXISTING),
            DWORD(FILE_FLAG_OPEN_REPARSE_POINT),
            nil
          )
        }
      }

      /// O_CREAT | O_EXCL equivalent.
      static func createExclusive(_ path: String) -> HANDLE {
        path.withCString(encodedAs: UTF16.self) {
          CreateFileW(
            $0,
            DWORD(GENERIC_WRITE),
            0,
            nil,
            DWORD(CREATE_NEW),
            DWORD(FILE_FLAG_OPEN_REPARSE_POINT),
            nil
          )
        }
      }

      /// O_RDWR | O_CREAT equivalent.
      static func openReadWriteOrCreate(_ path: String) -> HANDLE {
        path.withCString(encodedAs: UTF16.self) {
          CreateFileW(
            $0,
            // GENERIC_READ | GENERIC_WRITE
            DWORD(0x8000_0000) | DWORD(0x4000_0000),
            0,
            nil,
            DWORD(OPEN_ALWAYS),
            DWORD(FILE_FLAG_OPEN_REPARSE_POINT),
            nil
          )
        }
      }

      static func openDirectory(_ path: String) -> HANDLE {
        path.withCString(encodedAs: UTF16.self) {
          CreateFileW(
            $0,
            DWORD(FILE_READ_ATTRIBUTES),
            DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE),
            nil,
            DWORD(OPEN_EXISTING),
            DWORD(FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT),
            nil
          )
        }
      }

      struct Information {
        var device: UInt64
        var inode: UInt64
        var size: Int64
        var attributes: DWORD
        var lastWriteFileTime: UInt64
      }

      static func information(_ handle: HANDLE) -> Information? {
        var data = BY_HANDLE_FILE_INFORMATION()
        guard GetFileInformationByHandle(handle, &data) else { return nil }
        let lastWrite = data.ftLastWriteTime
        return Information(
          device: UInt64(data.dwVolumeSerialNumber),
          inode: (UInt64(data.nFileIndexHigh) << 32) | UInt64(data.nFileIndexLow),
          size: Int64(bitPattern: (UInt64(data.nFileSizeHigh) << 32) | UInt64(data.nFileSizeLow)),
          attributes: data.dwFileAttributes,
          lastWriteFileTime: (UInt64(lastWrite.dwHighDateTime) << 32)
            | UInt64(lastWrite.dwLowDateTime)
        )
      }

      static func isRegularFile(_ attributes: DWORD) -> Bool {
        attributes & DWORD(FILE_ATTRIBUTE_DIRECTORY) == 0
          && attributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT) == 0
      }

      static func remove(_ path: String) -> Bool {
        path.withCString(encodedAs: UTF16.self) { DeleteFileW($0) }
      }

      static func rename(_ from: String, to: String) -> Bool {
        from.withCString(encodedAs: UTF16.self) { source in
          to.withCString(encodedAs: UTF16.self) { destination in
            MoveFileExW(source, destination, DWORD(MOVEFILE_REPLACE_EXISTING))
          }
        }
      }

      static func flush(_ handle: HANDLE) -> Bool {
        FlushFileBuffers(handle)
      }

      static func close(_ handle: HANDLE) {
        _ = CloseHandle(handle)
      }

      static func fsyncDirectory(_ path: String) -> Bool {
        let handle = openDirectory(path)
        guard handle != INVALID_HANDLE_VALUE else { return false }
        defer { _ = CloseHandle(handle) }
        return FlushFileBuffers(handle)
      }

      static func read(_ handle: HANDLE, expectedCount: Int) -> Data? {
        var data = Data(count: expectedCount)
        var receivedTotal = 0
        let completed = data.withUnsafeMutableBytes { raw -> Bool in
          while receivedTotal < expectedCount {
            var received: DWORD = 0
            let succeeded = ReadFile(
              handle,
              raw.baseAddress!.advanced(by: receivedTotal),
              DWORD(expectedCount - receivedTotal),
              &received,
              nil
            )
            guard succeeded, received > 0 else { return false }
            receivedTotal += Int(received)
          }
          return true
        }
        return completed ? data : nil
      }

      static func touchLastWrite(_ handle: HANDLE) -> Bool {
        var now = FILETIME()
        GetSystemTimeAsFileTime(&now)
        return SetFileTime(handle, nil, nil, &now)
      }

      static func acquireExclusiveLock(_ handle: HANDLE) -> Bool {
        var overlapped = OVERLAPPED()
        return LockFileEx(
          handle,
          DWORD(LOCKFILE_EXCLUSIVE_LOCK | LOCKFILE_FAIL_IMMEDIATELY),
          0,
          DWORD.max,
          DWORD.max,
          &overlapped
        )
      }

      static func releaseLock(_ handle: HANDLE) {
        var overlapped = OVERLAPPED()
        _ = UnlockFileEx(handle, 0, DWORD.max, DWORD.max, &overlapped)
      }

      static func date(lastWriteFileTime raw: UInt64) -> Date {
        // FILETIME counts 100ns intervals since 1601-01-01.
        let unixEpochFileTime: UInt64 = 116_444_736_000_000_000
        guard raw >= unixEpochFileTime else { return Date(timeIntervalSince1970: 0) }
        return Date(timeIntervalSince1970: Double(raw - unixEpochFileTime) / 10_000_000)
      }
    }
  #endif

#endif
