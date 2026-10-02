#if os(Windows)
  import WinSDK

  /// Shared lifecycle and control primitives for the host frame. Page content lives
  /// in `BridgeDesktopUI`, so the host only ever creates the failure surface.
  enum WindowsUIFoundation {
    nonisolated(unsafe) private static var bodyFont: HFONT?

    static func initialize() {
      guard bodyFont == nil, let stockFont = GetStockObject(DEFAULT_GUI_FONT) else { return }
      bodyFont = unsafeBitCast(stockFont, to: HFONT.self)
    }

    static func shutdown() {
      bodyFont = nil
    }

    static func setText(_ control: HWND?, _ text: String) {
      text.withCString(encodedAs: UTF16.self) {
        _ = SetWindowTextW(control, $0)
      }
    }

    static func createChild(
      _ className: String,
      text: String = "",
      style: DWORD = 0,
      exStyle: DWORD = 0,
      parent: HWND?,
      instance: HINSTANCE?,
      id: Int
    ) -> HWND? {
      let created = className.withCString(encodedAs: UTF16.self) { classPointer in
        text.withCString(encodedAs: UTF16.self) { textPointer in
          CreateWindowExW(
            exStyle,
            classPointer,
            textPointer,
            DWORD(WS_CHILD) | DWORD(WS_VISIBLE) | style,
            0,
            0,
            0,
            0,
            parent,
            HMENU(bitPattern: id),
            instance,
            nil
          )
        }
      }
      if let bodyFont, let created {
        _ = SendMessageW(
          created,
          UINT(WM_SETFONT),
          WPARAM(UInt(bitPattern: bodyFont)),
          LPARAM(1)
        )
      }
      return created
    }
  }
#endif
