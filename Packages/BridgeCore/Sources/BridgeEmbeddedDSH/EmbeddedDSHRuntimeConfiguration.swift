import BridgeAgentCore
import Foundation

public struct EmbeddedDSHRuntimeConfiguration: Sendable {
  public let resourceRoot: URL?
  public let dataRoot: URL
  public let requestTimeout: Duration

  public init(
    resourceRoot: URL? = nil,
    dataRoot: URL,
    requestTimeout: Duration = .seconds(45)
  ) {
    self.resourceRoot = resourceRoot
    self.dataRoot = dataRoot
    self.requestTimeout = requestTimeout
  }

  func validatedDataRoot() throws -> URL {
    guard dataRoot.isFileURL,
      AgentPathSemantics.isAbsolute(dataRoot.path),
      !dataRoot.path.contains("\0"),
      requestTimeout > .zero
    else { throw EmbeddedDSHRuntimeError.invalidConfiguration }
    return dataRoot.standardizedFileURL
  }

  func resolveResourceRoot() throws -> URL {
    if let resourceRoot {
      guard resourceRoot.isFileURL, AgentPathSemantics.isAbsolute(resourceRoot.path) else {
        throw EmbeddedDSHRuntimeError.invalidConfiguration
      }
      return resourceRoot.resolvingSymlinksInPath().standardizedFileURL
    }

    var candidates: [URL] = []
    if let resources = Bundle.main.resourceURL {
      candidates.append(resources.appendingPathComponent("EmbeddedDSH", isDirectory: true))
    }
    if let executable = Bundle.main.executableURL {
      let directory = executable.deletingLastPathComponent()
      candidates.append(directory.appendingPathComponent("EmbeddedDSH", isDirectory: true))
      candidates.append(
        directory.deletingLastPathComponent()
          .appendingPathComponent("Resources/EmbeddedDSH", isDirectory: true))
    }
    #if DEBUG
      var directory = URL(
        fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
      for _ in 0..<6 {
        candidates.append(
          directory.appendingPathComponent(
            ".build/embedded-dsh/\(EmbeddedDSHRuntimeTarget.platform)-\(EmbeddedDSHRuntimeTarget.architecture)",
            isDirectory: true))
        directory.deleteLastPathComponent()
      }
    #endif
    guard
      let root = candidates.first(where: {
        FileManager.default.fileExists(atPath: $0.appendingPathComponent("runtime.json").path)
      })
    else { throw EmbeddedDSHRuntimeError.resourcesUnavailable }
    return root.resolvingSymlinksInPath().standardizedFileURL
  }
}

enum EmbeddedDSHRuntimeTarget {
  #if os(macOS)
    static let platform = "darwin"
  #elseif os(Windows)
    static let platform = "windows"
  #elseif os(Linux)
    static let platform = "linux"
  #else
    static let platform = "unsupported"
  #endif

  #if arch(arm64)
    static let architecture = "arm64"
  #elseif arch(x86_64)
    static let architecture = "x64"
  #else
    static let architecture = "unsupported"
  #endif
}
