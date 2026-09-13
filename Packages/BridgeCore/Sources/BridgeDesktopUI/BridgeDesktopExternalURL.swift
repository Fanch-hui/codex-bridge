import Foundation

public enum BridgeDesktopExternalURL {
  public static func resolve(_ value: String?) -> URL? {
    guard let value, let url = URL(string: value),
      let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
      let host = url.host, !host.isEmpty
    else { return nil }
    return url
  }
}
