import Foundation

enum LegacyProjectData {
  static func normalized(_ data: Data) throws -> Data {
    guard var envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      var project = envelope["project"] as? [String: Any]
    else { throw LegacyImportError.corruptRepository }
    project.removeValue(forKey: "accessPolicy")
    envelope["project"] = project
    return try JSONSerialization.data(
      withJSONObject: envelope, options: [.sortedKeys, .withoutEscapingSlashes])
  }
}
