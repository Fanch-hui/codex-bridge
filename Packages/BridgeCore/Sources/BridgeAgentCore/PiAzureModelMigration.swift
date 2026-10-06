import Foundation

public enum PiAzureModelMigration {
  public static let releaseNotesURL = "https://github.com/earendil-works/pi/releases/tag/v1.0.3"

  public static func isAzureModelID(_ modelID: String?) -> Bool {
    guard let modelID, modelID.hasPrefix("pi:") else { return false }
    var encoded = String(modelID.dropFirst(3))
      .replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
    guard let bytes = Data(base64Encoded: encoded),
      let identity = try? JSONDecoder().decode([String].self, from: bytes), identity.count == 2
    else { return false }
    return identity[0] == "azure" || identity[0] == "azure-openai-responses"
  }
}
