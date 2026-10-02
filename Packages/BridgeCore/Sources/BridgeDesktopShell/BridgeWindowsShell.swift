#if os(Windows) || os(Linux)
  import BridgeIPC
#endif

/// Desktop shell product metadata and the public Windows transport identifier.
public enum BridgeWindowsShellInfo {
  public static let productName = "Codex Bridge"
  #if os(Windows)
    public static var windowsPipeName: String { BridgeServiceIPC.windowsPipeName }
  #else
    public static let windowsPipeName = "\\\\.\\pipe\\org.codexbridge.service"
  #endif
}
