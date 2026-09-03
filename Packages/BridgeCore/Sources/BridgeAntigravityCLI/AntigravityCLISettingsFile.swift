import BridgeAgentCore
import Foundation

struct AntigravityCLISettingsFile: Sendable {
  struct Identity: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
  }

  struct Contents: Sendable {
    let data: Data
    let mode: UInt32
    let identity: Identity
  }

  let homeDirectory: String
  let settingsPath: String

  init(sourceEnvironment: [String: String]) throws {
    let home = try AgentProviderEnvironment.homeDirectory(source: sourceEnvironment)
    homeDirectory = home
    #if os(Windows)
      let geminiDir = URL(fileURLWithPath: home, isDirectory: true)
        .appendingPathComponent(".gemini", isDirectory: true)
      let cliDir = geminiDir.appendingPathComponent("antigravity-cli", isDirectory: true)
      settingsPath =
        cliDir.appendingPathComponent("settings.json", isDirectory: false)
        .standardizedFileURL.path
    #else
      settingsPath =
        URL(fileURLWithPath: home, isDirectory: true)
        .appendingPathComponent(".gemini/antigravity-cli/settings.json", isDirectory: false)
        .standardizedFileURL.path
    #endif
  }

  func revision(of contents: Contents?) -> String? {
    contents.map { AntigravityCLISettingsDocument.digest($0.data) }
  }
}
