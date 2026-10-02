#if os(Windows)
  import Foundation

  extension WindowsWebViewThread {
    func setLowMemoryUsage(_ low: Bool) {
      guard configuration.purpose == .chatBrowser else { return }
      let changed = lock.withLock { () -> Bool in
        guard pendingMemoryUsageLow != low else { return false }
        pendingMemoryUsageLow = low
        return true
      }
      if changed { post(Message.setMemoryUsageTarget) }
    }

    func applyMemoryUsageTarget() {
      guard configuration.purpose == .chatBrowser, let webView else { return }
      let low = lock.withLock { pendingMemoryUsageLow }
      var interfacePointer: UnsafeMutableRawPointer?
      var iid = iidCoreWebView2Version19
      let queryInterface: WebView2QueryInterfaceFn = webView2Method(
        webView, 0, as: WebView2QueryInterfaceFn.self)
      guard queryInterface(webView, &iid, &interfacePointer) == webview2SOK,
        let interfacePointer
      else { return }
      defer { _ = webView2Release(interfacePointer) }

      var currentLevel: UInt32 = 0
      let getLevel: WebView2GetMemoryUsageTargetLevelFn = webView2Method(
        interfacePointer,
        WebView2Slot.webView19GetMemoryUsageTargetLevel,
        as: WebView2GetMemoryUsageTargetLevelFn.self
      )
      guard getLevel(interfacePointer, &currentLevel) == webview2SOK else { return }

      let requestedLevel: UInt32 = low ? 1 : 0
      guard currentLevel != requestedLevel else { return }
      let putLevel: WebView2PutMemoryUsageTargetLevelFn = webView2Method(
        interfacePointer,
        WebView2Slot.webView19PutMemoryUsageTargetLevel,
        as: WebView2PutMemoryUsageTargetLevelFn.self
      )
      _ = putLevel(interfacePointer, requestedLevel)
    }
  }
#endif
