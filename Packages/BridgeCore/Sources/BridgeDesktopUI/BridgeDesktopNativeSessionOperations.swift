public enum BridgeDesktopNativeSessionOperations {
  public static func legacy(for providerID: String) -> [String] {
    guard providerID == "pi" || providerID == "qoder" else { return [] }
    return ["list", "read", "index", "rename", "delete", "continue"]
  }
}
