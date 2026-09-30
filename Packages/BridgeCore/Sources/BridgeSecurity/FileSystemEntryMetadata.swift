import Foundation

#if os(Windows)
  import WinSDK
#endif

public struct FileSystemEntryMetadata: Sendable {
  public let isDirectory: Bool
  public let isRegularFile: Bool
  public let isSymbolicLink: Bool
  public let fileSize: Int?

  public init(at url: URL) throws {
    #if os(Windows)
      var attributes = WIN32_FILE_ATTRIBUTE_DATA()
      let path = url.path.replacingOccurrences(of: "/", with: "\\")
      guard
        path.withCString(
          encodedAs: UTF16.self,
          {
            GetFileAttributesExW($0, GetFileExInfoStandard, &attributes)
          })
      else {
        throw NSError(domain: "NSWin32ErrorDomain", code: Int(GetLastError()))
      }
      isDirectory = attributes.dwFileAttributes & DWORD(FILE_ATTRIBUTE_DIRECTORY) != 0
      isSymbolicLink = attributes.dwFileAttributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT) != 0
      isRegularFile = !isDirectory && !isSymbolicLink
      fileSize = Int(
        exactly: (UInt64(attributes.nFileSizeHigh) << 32) | UInt64(attributes.nFileSizeLow))
    #else
      let values = try url.resourceValues(forKeys: [
        .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
      ])
      isDirectory = values.isDirectory == true
      isRegularFile = values.isRegularFile == true
      isSymbolicLink = values.isSymbolicLink == true
      fileSize = values.fileSize
    #endif
  }
}
