import Foundation

#if os(Windows)
  import WinSDK
#endif

/// Publishes a staged sibling file at its final location, replacing any existing file.
///
/// Swift corelibs Foundation on Windows does not implement `FileManager.replaceItemAt`
/// and traps at runtime, so Windows uses `MoveFileExW` with replace-existing semantics.
public enum FileReplacement {
  public struct Failure: Error, Equatable {
    public let code: Int32
  }

  public static func publish(_ staged: URL, at destination: URL) throws {
    #if os(Windows)
      let moved = staged.path.withCString(encodedAs: UTF16.self) { source in
        destination.path.withCString(encodedAs: UTF16.self) { target in
          MoveFileExW(
            source, target, DWORD(MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH))
        }
      }
      guard moved else { throw Failure(code: Int32(GetLastError())) }
    #else
      let manager = FileManager.default
      if manager.fileExists(atPath: destination.path) {
        _ = try manager.replaceItemAt(destination, withItemAt: staged)
      } else {
        try manager.moveItem(at: staged, to: destination)
      }
    #endif
  }
}
