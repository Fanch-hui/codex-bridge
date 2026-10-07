import BridgeAgentCore
import BridgeDeepSeekHarnessACP
import BridgeServiceCore
import Foundation

extension ServiceAgentAutoDiscovery {
  static func deepSeekDesktopRequests(existingPaths: [String], environment: [String: String]) throws
    -> [ServiceAgentRegistrationRequest]
  {
    guard ServiceDeepSeekDesktopInstallation.isSupported else { return [] }
    var paths: Set<String> = []
    return try (existingPaths + deepSeekDesktopCandidates(environment: environment)).compactMap {
      path in
      guard let executable = DeepSeekHarnessACPRuntimeLayout.desktop(at: path)?.runtimePath,
        paths.insert(executable).inserted
      else { return nil }
      return try .init(
        providerID: .deepSeekHarnessDesktop, displayName: "DSH 桌面",
        executablePath: executable, trustProfile: .userTrusted, enableOnSuccess: false,
        artifacts: [.init(role: .nodeInterpreter, path: executable)])
    }
  }

  static func deepSeekDesktopCandidates(environment: [String: String]) -> [String] {
    var candidates: [String] = []
    #if os(Windows)
      for key in ["ProgramFiles", "ProgramFiles(x86)"] {
        if let root = environmentValue(key, environment: environment) {
          candidates.append(pathJoin(root, "DeepSeek Harness", "DeepSeek Harness.exe"))
        }
      }
      if let local = environmentValue("LOCALAPPDATA", environment: environment) {
        candidates.append(pathJoin(local, "Programs", "DeepSeek Harness", "DeepSeek Harness.exe"))
        candidates.append(pathJoin(local, "Programs", "deepseek-harness", "DeepSeek Harness.exe"))
      }
    #elseif os(Linux)
      candidates += [
        "/opt/DeepSeek Harness/deepseek-harness", "/opt/deepseek-harness/deepseek-harness",
      ]
    #else
      candidates.append("/Applications/DeepSeek Harness.app/Contents/MacOS/DeepSeek Harness")
      if let home = homeDirectory(environment: environment) {
        candidates.append(
          pathJoin(
            home, "Applications", "DeepSeek Harness.app", "Contents", "MacOS", "DeepSeek Harness"))
      }
    #endif
    return candidates.compactMap { DeepSeekHarnessACPRuntimeLayout.desktop(at: $0)?.runtimePath }
  }

  static func deepSeekResolvedExecutable(_ path: String) -> String? {
    DeepSeekHarnessACPRuntimeLayout.desktop(at: path)?.runtimePath ?? canonicalRegularFile(path)
  }
}
