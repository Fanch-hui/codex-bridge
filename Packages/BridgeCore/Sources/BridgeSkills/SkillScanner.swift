import BridgeAgentCore
import Foundation

public actor SkillScanner {
  public static let maximumSkills = 256
  public static let maximumDocumentBytes = 64 * 1_024
  public static let maximumActionsPerSkill = 64

  private let globalRoots: [URL]
  private let fileManager: FileManager

  public init(
    globalRoots: [URL] = SkillScanner.defaultGlobalRoots(), fileManager: FileManager = .default
  ) {
    self.globalRoots = globalRoots.map { $0.standardizedFileURL }
    self.fileManager = fileManager
  }

  public static func defaultGlobalRoots(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
  ) -> [URL] {
    let homePath = userHomePath(environment: environment) ?? homeDirectory.path
    let home = URL(fileURLWithPath: homePath, isDirectory: true)
    var roots: [URL] = []
    if let codexHome = environmentValue("CODEX_HOME", in: environment),
      let codexHomeURL = absoluteURL(codexHome)
    {
      roots.append(codexHomeURL.appendingPathComponent("skills", isDirectory: true))
    }
    roots.append(contentsOf: [
      home.appendingPathComponent(".codex/skills", isDirectory: true),
      home.appendingPathComponent(".agents/skills", isDirectory: true),
      home.appendingPathComponent(".gemini/config/skills", isDirectory: true),
    ])
    return uniqueRoots(roots)
  }

  public func scanSkills(for projectRoot: URL?) throws -> [SkillManifest] {
    try SkillDirectoryScanner(globalRoots: globalRoots, fileManager: fileManager)
      .scan(projectRoot: projectRoot)
  }

  public func readSkillDocument(
    _ manifest: SkillManifest,
    subpath: String = "SKILL.md",
    maximumBytes: Int = SkillScanner.maximumDocumentBytes
  ) throws -> SkillDocument {
    try SkillDocumentReader.read(
      manifest,
      subpath: subpath,
      maximumBytes: maximumBytes,
      fileManager: fileManager
    )
  }

  /// Resolve an action to its launch representation (interpreter + resolved
  /// absolute script path). `nil` interpreter means the script is launched
  /// directly via its own shebang.
  public func resolveAction(
    _ actionName: String,
    in manifest: SkillManifest
  ) throws -> SkillActionLaunch {
    try SkillActionResolver.resolve(actionName, in: manifest, fileManager: fileManager)
  }

  public struct SkillActionLaunch: Sendable {
    public let action: SkillAction
    /// Fixed, fully resolved executable and argument prefix. Caller arguments
    /// are appended without shell interpretation.
    public let argvPrefix: [String]
    public var interpreter: String { argvPrefix.first ?? "" }
    public var resolvedScriptPath: String { argvPrefix.count > 1 ? argvPrefix[1] : "" }
  }

  private static func userHomePath(environment: [String: String]) -> String? {
    #if os(Windows)
      if let profile = environmentValue("USERPROFILE", in: environment) {
        return profile
      }
      if let drive = environmentValue("HOMEDRIVE", in: environment),
        let path = environmentValue("HOMEPATH", in: environment)
      {
        let combined = drive + path
        if !combined.isEmpty { return combined }
      }
    #endif
    return environmentValue("HOME", in: environment)
  }

  private static func environmentValue(
    _ name: String,
    in environment: [String: String]
  ) -> String? {
    guard
      let key = environment.keys.first(where: {
        $0.caseInsensitiveCompare(name) == .orderedSame
      })
    else {
      return nil
    }
    let value = environment[key] ?? ""
    return value.isEmpty ? nil : value
  }

  private static func absoluteURL(_ path: String) -> URL? {
    #if os(Windows)
      guard AgentPathSemantics.isAbsolute(path, style: .windows) else { return nil }
    #else
      guard AgentPathSemantics.isAbsolute(path, style: .posix) else { return nil }
    #endif
    return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
  }

  private static func uniqueRoots(_ roots: [URL]) -> [URL] {
    var seen = Set<String>()
    return roots.filter { root in
      let path = root.standardizedFileURL.path
      #if os(Windows)
        let key = path.lowercased()
      #else
        let key = path
      #endif
      return seen.insert(key).inserted
    }
  }
}
