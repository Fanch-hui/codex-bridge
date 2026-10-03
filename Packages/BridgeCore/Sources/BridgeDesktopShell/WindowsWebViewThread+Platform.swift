#if os(Windows)
  import Foundation
  import WinSDK

  extension WindowsWebViewThread {
    func complete() {
      let notification = lock.withLock { () -> (window: HWND, message: UINT)? in
        completed = true
        threadID = 0
        return shutdownNotification
      }
      if let finished { _ = SetEvent(finished) }
      if let notification {
        _ = PostMessageW(notification.window, notification.message, 0, 0)
      }
    }

    func releaseInterfaces() {
      if let webView, hasWebMessageToken {
        let removeMessageHandler: WebView2RemoveWebMessageReceivedFn = webView2Method(
          webView, WebView2Slot.webViewRemoveWebMessageReceived,
          as: WebView2RemoveWebMessageReceivedFn.self
        )
        _ = removeMessageHandler(webView, webMessageToken)
      }
      if let webMessageHandler { _ = webView2Release(webMessageHandler) }
      webMessageHandler = nil
      hasWebMessageToken = false

      if let webView, hasHistoryChangedToken {
        let removeHandler: WebView2RemoveEventHandlerFn = webView2Method(
          webView, WebView2Slot.webViewRemoveHistoryChanged,
          as: WebView2RemoveEventHandlerFn.self
        )
        _ = removeHandler(webView, historyChangedToken)
      }
      if let historyChangedHandler { _ = webView2Release(historyChangedHandler) }
      historyChangedHandler = nil
      hasHistoryChangedToken = false

      if let webView, hasNavigationCompletedToken {
        let removeHandler: WebView2RemoveEventHandlerFn = webView2Method(
          webView, WebView2Slot.webViewRemoveNavigationCompleted,
          as: WebView2RemoveEventHandlerFn.self
        )
        _ = removeHandler(webView, navigationCompletedToken)
      }
      if let navigationCompletedHandler { _ = webView2Release(navigationCompletedHandler) }
      navigationCompletedHandler = nil
      hasNavigationCompletedToken = false

      if let controller {
        let close: WebView2ActionFn = webView2Method(
          controller, WebView2Slot.controllerClose, as: WebView2ActionFn.self)
        _ = close(controller)
      }
      for object in [webView, controller, environment].compactMap({ $0 }) {
        _ = webView2Release(object)
      }
      webView = nil
      controller = nil
      environment = nil
    }

    func loadLoader() -> HMODULE? {
      var buffer = [WCHAR](repeating: 0, count: 32_768)
      let length = buffer.withUnsafeMutableBufferPointer { raw in
        GetModuleFileNameW(nil, raw.baseAddress, DWORD(raw.count))
      }
      guard length > 0, length < DWORD(buffer.count) else { return nil }
      let executable = String(decoding: buffer.prefix(Int(length)), as: UTF16.self)
      guard let separator = executable.lastIndex(of: "\\") else { return nil }
      let path = String(executable[..<separator]) + "\\WebView2Loader.dll"
      return path.withCString(encodedAs: UTF16.self) { LoadLibraryW($0) }
    }

    func loadCreateFunction(_ loader: HMODULE) -> WebView2CreateEnvironmentFn? {
      guard
        let address = "CreateCoreWebView2EnvironmentWithOptions".withCString({
          GetProcAddress(loader, $0)
        })
      else { return nil }
      return unsafeBitCast(address, to: WebView2CreateEnvironmentFn.self)
    }

    func userDataFolderPath() -> String? {
      let required = "LOCALAPPDATA".withCString(encodedAs: UTF16.self) {
        GetEnvironmentVariableW($0, nil, 0)
      }
      guard required > 0 else { return nil }
      var buffer = [WCHAR](repeating: 0, count: Int(required))
      let written = "LOCALAPPDATA".withCString(encodedAs: UTF16.self) {
        GetEnvironmentVariableW($0, &buffer, required)
      }
      guard written > 0 else { return nil }
      var path = String(decoding: buffer.prefix(Int(written)), as: UTF16.self)
      if path.hasSuffix("\\") { path.removeLast() }
      return path + "\\CodexBridge\\" + profileName
    }

    func ensureDirectoryExists(_ path: String) {
      let root = path.dropLast(profileName.count + 1)
      for directory in [String(root), path] {
        directory.withCString(encodedAs: UTF16.self) { _ = CreateDirectoryW($0, nil) }
      }
    }

    func hresult(_ value: HRESULT) -> String {
      String(format: "0x%08X", UInt32(bitPattern: value))
    }
  }
#endif
