import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#elseif os(Windows)
  import WinSDK
#endif

public final class OpenedWorkingDirectory: @unchecked Sendable {
  public let url: URL
  #if os(Windows)
    private let handle: HANDLE
    private let device: UInt64
    private let inode: UInt64

    var identity: GitRootIdentity {
      GitRootIdentity(device: device, inode: inode)
    }

    public init(canonicalURL: URL) throws {
      let opened: HANDLE? = canonicalURL.path.withCString(encodedAs: UTF16.self) {
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
      var information = BY_HANDLE_FILE_INFORMATION()
      guard let opened, opened != INVALID_HANDLE_VALUE,
        GetFileInformationByHandle(opened, &information),
        information.dwFileAttributes & DWORD(FILE_ATTRIBUTE_DIRECTORY) != 0,
        information.dwFileAttributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT) == 0
      else {
        if let opened, opened != INVALID_HANDLE_VALUE { _ = CloseHandle(opened) }
        throw GitEvidenceError.invalidAuthorizedRoot
      }
      url = canonicalURL
      handle = opened
      device = UInt64(information.dwVolumeSerialNumber)
      inode = (UInt64(information.nFileIndexHigh) << 32) | UInt64(information.nFileIndexLow)
    }

    deinit {
      _ = CloseHandle(handle)
    }

    public func validatePathIdentity() throws {
      let current = url.path.withCString(encodedAs: UTF16.self) {
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
      defer {
        if current != INVALID_HANDLE_VALUE { _ = CloseHandle(current) }
      }
      var information = BY_HANDLE_FILE_INFORMATION()
      guard current != INVALID_HANDLE_VALUE, GetFileInformationByHandle(current, &information),
        information.dwFileAttributes & DWORD(FILE_ATTRIBUTE_DIRECTORY) != 0,
        UInt64(information.dwVolumeSerialNumber) == device,
        (UInt64(information.nFileIndexHigh) << 32) | UInt64(information.nFileIndexLow) == inode
      else {
        throw GitEvidenceError.invalidAuthorizedRoot
      }
    }
  #else
    public let descriptor: Int32
    private let device: UInt64
    private let inode: UInt64

    var identity: GitRootIdentity {
      GitRootIdentity(device: device, inode: inode)
    }

    public init(canonicalURL: URL) throws {
      var information = stat()
      let opened = Darwin.open(canonicalURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
      guard opened >= 0, fstat(opened, &information) == 0,
        information.st_mode & S_IFMT == S_IFDIR
      else {
        if opened >= 0 { Darwin.close(opened) }
        throw GitEvidenceError.invalidAuthorizedRoot
      }
      url = canonicalURL
      descriptor = opened
      device = UInt64(information.st_dev)
      inode = UInt64(information.st_ino)
    }

    deinit {
      Darwin.close(descriptor)
    }

    public func validatePathIdentity() throws {
      var information = stat()
      let result = url.path.withCString { Darwin.lstat($0, &information) }
      guard result == 0,
        information.st_mode & S_IFMT == S_IFDIR,
        UInt64(information.st_dev) == device,
        UInt64(information.st_ino) == inode
      else {
        throw GitEvidenceError.invalidAuthorizedRoot
      }
    }
  #endif
}
