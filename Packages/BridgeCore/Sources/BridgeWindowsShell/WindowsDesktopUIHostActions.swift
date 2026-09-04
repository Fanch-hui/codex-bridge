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

    static func chooseExecutableFile(
      title: String = "选择 Agent 可执行文件",
      completion: @escaping @Sendable (_ path: String) -> Void
    ) {
      let filter = "可执行文件 (*.exe;*.cmd;*.bat)\0*.exe;*.cmd;*.bat\0所有文件 (*.*)\0*.*\0"
      chooseFile(title: title, filter: filter, completion: completion)
    }

    static func chooseConfigFile(
      title: String = "选择 Agent 配置文件",
      completion: @escaping @Sendable (_ path: String) -> Void
    ) {
      let filter = "配置文件 (*.yml;*.yaml;*.json)\0*.yml;*.yaml;*.json\0所有文件 (*.*)\0*.*\0"
      chooseFile(title: title, filter: filter, completion: completion)
    }

    static func chooseFile(
      title: String,
      filter: String,
      completion: @escaping @Sendable (_ path: String) -> Void
    ) {
      WindowsUIThread.shared.enqueue {
        guard let path = openFileDialog(title: title, filter: filter) else { return }
        completion(path)
      }
    }

    private static func openFileDialog(title: String, filter: String) -> String? {
      var fileName = [WCHAR](repeating: 0, count: Int(MAX_PATH))
      var filterChars = [WCHAR]()
      for char in filter.utf16 {
        filterChars.append(char)
      }
      if filterChars.last != 0 { filterChars.append(0) }
      filterChars.append(0)

      return title.withCString(encodedAs: UTF16.self) { titlePointer in
        filterChars.withUnsafeBufferPointer { filterPointer in
          fileName.withUnsafeMutableBufferPointer { filePointer in
            var ofn = OPENFILENAMEW()
            ofn.lStructSize = DWORD(MemoryLayout<OPENFILENAMEW>.size)
            ofn.hwndOwner = WindowsMainWindow.currentWindow()
            ofn.lpstrFilter = filterPointer.baseAddress
            ofn.lpstrFile = filePointer.baseAddress
            ofn.nMaxFile = DWORD(MAX_PATH)
            ofn.lpstrTitle = titlePointer
            ofn.Flags = DWORD(OFN_FILEMUSTEXIST | OFN_PATHMUSTEXIST | OFN_NOCHANGEDIR)
            guard GetOpenFileNameW(&ofn) else { return nil }
            return String(decoding: filePointer.prefix { $0 != 0 }, as: UTF16.self)
          }
        }
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
