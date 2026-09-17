#if os(Windows)
  import WinSDK

  /// Reads the Windows app appearance once so the native host and the first
  /// WebView2 frame use the same canvas before the page has applied its CSS.
  enum WindowsSystemAppearance {
    private static let keyReadAccess: REGSAM = 0x0002_0019
    private static let personalizationKey =
      "Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize"
    private static let appsUseLightTheme = "AppsUseLightTheme"

    static let isDark = readIsDark()

    static let canvasColor: (r: UInt8, g: UInt8, b: UInt8, a: UInt8) =
      isDark
      ? (r: 32, g: 32, b: 32, a: 255)
      : (r: 250, g: 250, b: 250, a: 255)

    static var canvasColorRef: COLORREF {
      COLORREF(canvasColor.r)
        | (COLORREF(canvasColor.g) << 8)
        | (COLORREF(canvasColor.b) << 16)
    }

    private static func readIsDark() -> Bool {
      var key: HKEY?
      let openStatus = personalizationKey.withCString(encodedAs: UTF16.self) { subkey in
        RegOpenKeyExW(HKEY_CURRENT_USER, subkey, 0, keyReadAccess, &key)
      }
      guard openStatus == ERROR_SUCCESS, let key else { return false }
      defer { RegCloseKey(key) }

      var type: DWORD = 0
      var value: DWORD = 1
      var byteCount = DWORD(MemoryLayout<DWORD>.size)
      let status = appsUseLightTheme.withCString(encodedAs: UTF16.self) { valueName in
        withUnsafeMutableBytes(of: &value) { bytes in
          RegQueryValueExW(
            key,
            valueName,
            nil,
            &type,
            bytes.baseAddress?.assumingMemoryBound(to: BYTE.self),
            &byteCount
          )
        }
      }
      return status == ERROR_SUCCESS && type == DWORD(REG_DWORD) && value == 0
    }
  }
#endif
