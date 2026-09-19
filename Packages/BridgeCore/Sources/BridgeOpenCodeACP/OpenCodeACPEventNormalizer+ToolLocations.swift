import BridgeACP
import BridgeAgentCore
import Foundation

extension OpenCodeACPEventNormalizer {
  static func absoluteLocations(
    from input: [String: ACPJSONValue],
    projectRoot: String?
  ) -> [String] {
    let keys = [
      "path", "filePath", "filepath", "file_path", "file", "source", "destination",
    ]
    return Array(
      Set(
        keys.compactMap { key in
          input[key]?.stringValue.flatMap { absolutePath($0, projectRoot: projectRoot) }
        })
    ).sorted()
  }

  static func absolutePath(_ value: String, projectRoot: String?) -> String? {
    guard !value.isEmpty, value.utf8.count <= 1_024,
      !value.contains("\0"), value.rangeOfCharacter(from: .controlCharacters) == nil
    else { return nil }
    if AgentPathSemantics.isAbsolute(value) {
      guard
        let canonical = OpenCodeACPPathSupport.canonicalFilesystemPath(
          value,
          resolvingSymlinks: false
        )
      else {
        return nil
      }
      if let projectRoot, !AgentPathSemantics.isContained(canonical, in: projectRoot) {
        return nil
      }
      return canonical
    }
    guard let projectRoot,
      AgentPathSemantics.relativeComponents(value) != nil,
      let canonical = OpenCodeACPPathSupport.canonicalFilesystemPath(
        URL(fileURLWithPath: projectRoot, isDirectory: true)
          .appendingPathComponent(value).path,
        resolvingSymlinks: false
      ),
      AgentPathSemantics.isContained(canonical, in: projectRoot)
    else {
      return nil
    }
    return canonical
  }

}
