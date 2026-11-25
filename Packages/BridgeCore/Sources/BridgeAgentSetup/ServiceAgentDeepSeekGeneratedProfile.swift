import BridgeDeepSeekHarnessACP
import Foundation

enum ServiceAgentDeepSeekGeneratedProfile {
  private static let legacyTemplateDigests: Set<String> = [
    "1cf2e9c889fe2e797bacc8c198182cb2e271109f5d96d542c7e601ee9b2f7cab",
    "2c67da4933fc561ad6bf41a3f523f66aa91e4eec704a694a60eee45a7a060815",
    "f2f740d823cf7671d4b5035fbaa1d1b7788f48cd64751313348ef1b391611b32",
  ]

  static func refresh(at configuration: URL, stateRoot: URL) throws {
    let directory = stateRoot.resolvingSymlinksInPath().standardizedFileURL
      .appendingPathComponent("DeepSeekHarnessAuto", isDirectory: true)
    let expected = directory.appendingPathComponent("cordis.yml")
    let requested = stateRoot.appendingPathComponent("DeepSeekHarnessAuto/cordis.yml")
      .standardizedFileURL
    guard [requested, expected].contains(configuration.standardizedFileURL),
      directory.resolvingSymlinksInPath().standardizedFileURL == directory,
      configuration.resolvingSymlinksInPath().standardizedFileURL == expected
    else { return }
    let handle = try FileHandle(forReadingFrom: configuration)
    defer { try? handle.close() }
    let maximumBytes = DeepSeekHarnessACPConstants.maximumFinalTextBytes
    let content = try handle.read(upToCount: maximumBytes + 1)
    try handle.close()
    guard let data = content, !data.isEmpty, data.count <= maximumBytes,
      let text = String(data: data, encoding: .utf8)
    else { return }
    let normalized = Data(text.replacingOccurrences(of: "\r\n", with: "\n").utf8)
    guard
      legacyTemplateDigests.contains(
        try DeepSeekHarnessACPProfile(configurationTemplate: normalized).configurationTemplateDigest
      )
    else { return }
    try DeepSeekHarnessACPProfile.bundledConfigurationTemplate()
      .write(to: configuration, options: .atomic)
    #if !os(Windows)
      try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: configuration.path)
    #endif
  }
}
