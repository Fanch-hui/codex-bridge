#if os(Windows)
  import Foundation
  import WinSDK

  enum WindowsApplicationIcon {
    private static let standardResourceID = 32_512
    private static let imageIcon: UINT = 1
    private static let lrLoadFromFile: UINT = 0x0010
    private static let lrDefaultSize: UINT = 0x0040

    static func load(width: Int32 = 0, height: Int32 = 0) -> HICON? {
      if let module = GetModuleHandleW(nil) {
        if let exePath = executablePath(module), let separator = lastSeparator(in: exePath) {
          let exeDir = String(exePath[..<separator])
          let candidates = iconCandidates(in: exeDir)
          for candidate in candidates {
            if FileManager.default.fileExists(atPath: candidate) {
              let handle = candidate.withCString(encodedAs: UTF16.self) { pathPointer in
                LoadImageW(
                  nil,
                  pathPointer,
                  imageIcon,
                  width,
                  height,
                  lrLoadFromFile | (width == 0 && height == 0 ? lrDefaultSize : 0)
                )
              }
              if let handle {
                return autoCast(handle)
              }
            }
          }
        }
        return LoadIconW(module, resourcePointer(standardResourceID))
      }
      return nil
    }

    private static func executablePath(_ module: HMODULE) -> String? {
      var pathBuffer = [WCHAR](repeating: 0, count: 32_768)
      let length = GetModuleFileNameW(module, &pathBuffer, DWORD(pathBuffer.count))
      guard length > 0, length < DWORD(pathBuffer.count) else { return nil }
      return String(decoding: pathBuffer.prefix(Int(length)), as: UTF16.self)
    }

    private static func lastSeparator(in path: String) -> String.Index? {
      path.lastIndex(where: { $0 == "\\" || $0 == "/" })
    }

    private static func iconCandidates(in directory: String) -> [String] {
      var candidates = [directory + "\\AppIcon.ico", directory + "\\Resources\\AppIcon.ico"]
      let resourceDirectories =
        (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
      for name in resourceDirectories where name.localizedCaseInsensitiveContains("BridgeDesktopUI")
      {
        guard name.hasSuffix(".resources") || name.hasSuffix(".bundle") else { continue }
        candidates.append(directory + "\\" + name + "\\AppIcon.ico")
      }
      return candidates
    }

    private static func resourcePointer(_ id: Int) -> UnsafePointer<WCHAR> {
      UnsafePointer<WCHAR>(bitPattern: id)!
    }

    private static func autoCast<T, U>(_ value: T) -> U {
      unsafeBitCast(value, to: U.self)
    }
  }
#endif
