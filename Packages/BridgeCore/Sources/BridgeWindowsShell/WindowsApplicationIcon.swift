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
        var pathBuffer = [WCHAR](repeating: 0, count: Int(MAX_PATH))
        let length = GetModuleFileNameW(module, &pathBuffer, DWORD(MAX_PATH))
        if length > 0 {
          let exePath = String(decodingCString: pathBuffer, as: UTF16.self)
          let exeDir = URL(fileURLWithPath: exePath).deletingLastPathComponent()
          let candidates = [
            exeDir.appendingPathComponent("AppIcon.ico").path,
            exeDir.appendingPathComponent("Resources").appendingPathComponent("AppIcon.ico").path,
            exeDir.appendingPathComponent("BridgeDesktopUI_BridgeDesktopUI.resources")
              .appendingPathComponent("AppIcon.ico").path,
          ]
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
      }
      return LoadIconW(nil, resourcePointer(standardResourceID))
    }

    private static func resourcePointer(_ id: Int) -> UnsafePointer<WCHAR> {
      UnsafePointer<WCHAR>(bitPattern: id)!
    }

    private static func autoCast<T, U>(_ value: T) -> U {
      unsafeBitCast(value, to: U.self)
    }
  }
#endif
