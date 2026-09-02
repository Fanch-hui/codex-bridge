#if os(Windows)
  import Foundation
  import WinSDK

  enum WindowsDesktopUIHostActions {
    static func chooseProjectDirectory(
      completion: @escaping @Sendable (_ name: String, _ path: String) -> Void
    ) {
      WindowsUIThread.shared.enqueue {
        guard let path = chooseDirectory() else { return }
        let name =
          path.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last.map(String.init)
          ?? path
        completion(name, path)
      }
    }

    private static func chooseDirectory() -> String? {
      var displayName = [WCHAR](repeating: 0, count: Int(MAX_PATH))
      let title = "选择要注册到 Codex Bridge 的项目目录"
      let selected = title.withCString(encodedAs: UTF16.self) { titlePointer in
        displayName.withUnsafeMutableBufferPointer { displayPointer in
          var info = BROWSEINFOW()
          info.hwndOwner = WindowsMainWindow.currentWindow()
          info.pszDisplayName = displayPointer.baseAddress
          info.lpszTitle = titlePointer
          info.ulFlags = UINT(BIF_RETURNONLYFSDIRS | BIF_NEWDIALOGSTYLE)
          return SHBrowseForFolderW(&info)
        }
      }
      guard let selected else { return nil }
      defer { CoTaskMemFree(selected) }
      var path = [WCHAR](repeating: 0, count: Int(MAX_PATH))
      guard
        path.withUnsafeMutableBufferPointer({
          SHGetPathFromIDListW(selected, $0.baseAddress)
        })
      else { return nil }
      return String(decoding: path.prefix { $0 != 0 }, as: UTF16.self)
    }
  }
#endif
