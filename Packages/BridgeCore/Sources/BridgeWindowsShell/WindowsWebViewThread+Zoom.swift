#if os(Windows)
  import WinSDK

  extension WindowsWebViewThread {
    func resetDesktopUIZoomFactor(_ controller: UnsafeMutableRawPointer) {
      guard let zoomFactor = configuration.defaultZoomFactor else { return }
      let putZoomFactor: WebView2PutDoubleFn = webView2Method(
        controller,
        WebView2Slot.controllerPutZoomFactor,
        as: WebView2PutDoubleFn.self
      )
      _ = putZoomFactor(controller, zoomFactor)
    }
  }
#endif
