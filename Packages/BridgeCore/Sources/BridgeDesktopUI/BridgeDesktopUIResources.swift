import Foundation

public enum BridgeDesktopUIResource: String, CaseIterable, Sendable {
  case indexHTML = "index.html"
  case stylesCSS = "styles.css"
  case appJS = "app.js"
}

public enum BridgeDesktopUIResources {
  public static func url(for resource: BridgeDesktopUIResource) -> URL? {
    Bundle.module.url(forResource: resource.rawValue, withExtension: nil)
  }

  public static func read(_ resource: BridgeDesktopUIResource) throws -> String {
    guard let url = url(for: resource) else {
      throw NSError(
        domain: "BridgeDesktopUIResources",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Missing bundled resource: \(resource.rawValue)"]
      )
    }
    return try String(contentsOf: url, encoding: .utf8)
  }
}

public enum BridgeDesktopUI {
  public static func indexURL() -> URL? {
    BridgeDesktopUIResources.url(for: .indexHTML)
  }

  public static func resourceURL(_ resource: BridgeDesktopUIResource) -> URL? {
    BridgeDesktopUIResources.url(for: resource)
  }
}
