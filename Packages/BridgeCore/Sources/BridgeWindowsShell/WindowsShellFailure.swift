#if os(Windows)
  import WinSDK

  /// Fail-closed diagnostic surface for the host frame: shown only when the shared
  /// desktop UI cannot load, never as a substitute page.
  enum WindowsShellFailure {
    private static let controlID = 1400
    private static let horizontalPadding = 32
    private static let lineHeight = 22

    nonisolated(unsafe) private static var label: HWND?

    static func present(_ text: String?, in parent: HWND?) {
      guard let text, let parent else {
        _ = ShowWindow(label, SW_HIDE)
        return
      }
      let instance = GetModuleHandleW(nil)
      let control =
        label
        ?? WindowsUIFoundation.createChild(
          "STATIC",
          text: text,
          style: DWORD(SS_LEFT),
          exStyle: DWORD(WS_EX_TRANSPARENT),
          parent: parent,
          instance: instance,
          id: controlID
        )
      label = control
      guard let control else { return }
      WindowsUIFoundation.setText(control, text)
      _ = ShowWindow(control, SW_SHOW)
      _ = SetWindowPos(
        control,
        nil,  // HWND_TOP: the diagnostic must sit above the WebView2 sibling.
        0,
        0,
        0,
        0,
        UINT(SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE)
      )
      // The control is created with an empty rect; sizing it here keeps the first
      // failure report readable without waiting for an unrelated layout pass.
      var area = RECT()
      if GetClientRect(parent, &area) { layout(in: area) }
    }

    static func layout(in bounds: RECT) {
      guard let label else { return }
      let width = max(Int32(0), bounds.right - bounds.left)
      let height = max(Int32(0), bounds.bottom - bounds.top)
      let boxWidth = max(Int32(0), width - Int32(horizontalPadding * 2))
      let boxHeight = Int32(lineHeight * 4)
      _ = MoveWindow(
        label,
        bounds.left + Int32(horizontalPadding),
        bounds.top + max(0, (height - boxHeight) / 2),
        boxWidth,
        boxHeight,
        true
      )
    }

    static func shutdown() {
      label = nil
    }
  }
#endif
