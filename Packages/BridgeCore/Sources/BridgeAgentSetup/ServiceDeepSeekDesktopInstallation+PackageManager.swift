import BridgeAgentCore
import BridgeSecurity
import Foundation

extension ServiceDeepSeekDesktopInstallation {
  func packageManagerArguments(cwd: URL) -> [String] {
    guard let profile = desktopProfileDirectory(cwd: cwd),
      let metadata = try? SecureFileArtifactReader.read(
        at: profile.appendingPathComponent("node_modules/.modules.yaml").path,
        maximumBytes: 1_024 * 1_024)
    else { return [] }
    return Self.packageManagerArguments(metadata: metadata)
  }

  static func packageManagerArguments(
    metadata: Data, style: AgentPathStyle = .current
  ) -> [String] {
    // pnpm 11 writes its modules manifest as JSON, despite the historical filename.
    guard let modules = try? JSONDecoder().decode(PnpmModulesMetadata.self, from: metadata),
      AgentPathSemantics.isAbsolute(modules.storeDir, style: style),
      !modules.storeDir.contains("\0"), modules.storeDir.utf8.count <= 32 * 1_024
    else { return [] }
    return ["--store-dir", modules.storeDir]
  }

  func desktopProfileDirectory(cwd: URL) -> URL? {
    guard let home = try? AgentProviderEnvironment.homeDirectory(source: environment) else {
      return nil
    }
    let configured = environment["DSH_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? "~/.dsh"
    guard !configured.contains("\0"), configured.utf8.count <= 32 * 1_024 else { return nil }
    let expanded: String
    if configured == "~" {
      expanded = home
    } else if configured.hasPrefix("~/") || configured.hasPrefix("~\\") {
      expanded = home + "/" + configured.dropFirst(2)
    } else {
      expanded = configured
    }
    let directory = URL(fileURLWithPath: cwd.path, isDirectory: true)
    return URL(fileURLWithPath: expanded, isDirectory: true, relativeTo: directory)
      .standardizedFileURL.appendingPathComponent("profiles/desktop", isDirectory: true)
  }
}

private struct PnpmModulesMetadata: Decodable {
  let storeDir: String
}
