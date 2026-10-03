#if os(Windows)
  import WinSDK

  enum WindowsWebViewMessageRoute: Equatable {
    case thread
    case window
  }

  extension WindowsWebViewThread {
    static func messageRoute(for message: MSG) -> WindowsWebViewMessageRoute {
      message.hwnd == nil ? .thread : .window
    }
  }
#endif
