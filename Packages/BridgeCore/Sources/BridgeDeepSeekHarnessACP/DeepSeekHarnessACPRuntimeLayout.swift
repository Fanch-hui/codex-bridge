import BridgeAgentCore
import Foundation

public struct DeepSeekHarnessACPRuntimeLayout: Equatable, Sendable {
  public enum Kind: Equatable, Sendable { case legacyDemo, modernNode, desktopElectron }
  public let kind: Kind
  public let runtimePath: String
  public let entryPath: String
  public let archivePath: String?
  public let usesMessagesProvider: Bool
  public var isModernProfile: Bool { kind != .legacyDemo }
  public var runtimeArguments: [String] { kind == .desktopElectron ? ["--expose-internals"] : [] }
  public var environment: [String: String] {
    kind == .desktopElectron ? ["ELECTRON_RUN_AS_NODE": "1"] : [:]
  }

  public static func isModernEntry(_ installation: AgentInstallation) -> Bool {
    desktop(at: installation.executablePath) != nil
      || DeepSeekHarnessACPModernLaunch.isModernEntry(installation.executablePath)
  }

  public static func usesMessagesProvider(_ installation: AgentInstallation) -> Bool {
    if let desktop = desktop(at: installation.executablePath) {
      return desktop.usesMessagesProvider
    }
    var root = URL(fileURLWithPath: installation.executablePath).deletingLastPathComponent()
    for _ in 0..<8 {
      let candidates = [
        root.appendingPathComponent(
          "node_modules/@deepseek-ai/dsh-llm-deepseek/lib/types/config.d.ts"),
        root.appendingPathComponent("packages/llm/llm-deepseek/src/config.ts"),
      ]
      if candidates.contains(where: { url in
        guard
          let data = try? DeepSeekHarnessACPArtifactRuntime.boundedData(
            at: url.path,
            maximumBytes: 2 * 1_024 * 1_024, field: "provider.schema")
        else { return false }
        return messagesSchema(data)
      }) {
        return true
      }
      let parent = root.deletingLastPathComponent()
      if parent == root { break }
      root = parent
    }
    return false
  }

  private static func messagesSchema(_ data: Data) -> Bool {
    let schema = String(decoding: data, as: UTF8.self)
    return schema.contains("Messages") && schema.contains("thinking")
      && schema.contains("streamIdleTimeoutMs")
  }

  static func node(runtimePath: String, entryPath: String) -> Self {
    let installation = try? AgentInstallation(
      id: .init(rawValue: "layout"), providerID: .deepSeekHarness, executablePath: entryPath)
    return Self(
      kind: DeepSeekHarnessACPModernLaunch.isModernEntry(entryPath) ? .modernNode : .legacyDemo,
      runtimePath: runtimePath, entryPath: entryPath, archivePath: nil,
      usesMessagesProvider: installation.map(Self.usesMessagesProvider) ?? false)
  }

  public static func desktop(at path: String) -> Self? {
    guard let pair = desktopPair(at: path),
      let archive = try? DeepSeekHarnessACPArchive(path: pair.archive),
      let manifest = try? archive.data(
        "dsh/node_modules/@deepseek-ai/dsh-desktop-host/package.json"),
      let object = try? JSONSerialization.jsonObject(with: manifest) as? [String: Any],
      object["name"] as? String == "@deepseek-ai/dsh-desktop-host",
      archive.entry(desktopEntry) != nil,
      FileManager.default.isExecutableFile(atPath: pair.runtime)
    else { return nil }
    return Self(
      kind: .desktopElectron, runtimePath: pair.runtime,
      entryPath: pair.archive + "/" + desktopEntry, archivePath: pair.archive,
      usesMessagesProvider: (try? archive.data(
        "dsh/node_modules/@deepseek-ai/dsh-llm-deepseek/lib/types/config.d.ts"))
        .map(messagesSchema) ?? false)
  }

  private static let desktopEntry = "dsh/node_modules/@deepseek-ai/dsh-desktop-host/lib/cli.js"

  private static func desktopPair(at path: String) -> (runtime: String, archive: String)? {
    var url = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
    for _ in 0..<8 {
      let macRuntime = url.appendingPathComponent("Contents/MacOS/DeepSeek Harness").path
      let macArchive = url.appendingPathComponent("Contents/Resources/app.asar").path
      if FileManager.default.fileExists(atPath: macRuntime),
        FileManager.default.fileExists(atPath: macArchive)
      {
        return (macRuntime, macArchive)
      }
      let runtime = url.appendingPathComponent("DeepSeek Harness.exe").path
      let archive = url.appendingPathComponent("resources/app.asar").path
      if FileManager.default.fileExists(atPath: runtime),
        FileManager.default.fileExists(atPath: archive)
      {
        return (runtime, archive)
      }
      #if os(Linux)
        for name in ["deepseek-harness", "DeepSeek Harness", "dsh"] {
          let linuxRuntime = url.appendingPathComponent(name).path
          if FileManager.default.fileExists(atPath: linuxRuntime),
            FileManager.default.fileExists(atPath: archive)
          {
            return (linuxRuntime, archive)
          }
        }
      #endif
      let parent = url.deletingLastPathComponent()
      if parent == url { break }
      url = parent
    }
    return nil
  }
}
