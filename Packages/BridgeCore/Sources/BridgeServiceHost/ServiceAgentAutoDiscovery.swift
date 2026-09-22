import BridgeAgentCore
import BridgeServiceApplication
import BridgeServiceCore
import Foundation

#if canImport(Darwin)
  import Darwin
#endif

enum ServiceAgentAutoDiscovery {
  static func registrationRequests(
    providerID: AgentProviderID,
    dataPaths: ServiceDataPaths,
    existingInstallations: [ServiceAgentInstallationRecord] = [],
    credentialsProvided: Bool = false,
    environment: [String: String] = ToolDiscoveryEnvironment.current(),
    allowGeneratedConfiguration: Bool = true,
    discoveredExecutablePath: String? = nil
  ) throws -> [ServiceAgentRegistrationRequest] {
    var existingPaths = existingInstallations.map(\.executablePath)
    if let discoveredExecutablePath {
      existingPaths.insert(discoveredExecutablePath, at: 0)
    }
    switch providerID {
    case .openCode:
      return try commandLineRequests(
        providerID: providerID,
        names: ["opencode", "opencode-cli"],
        displayName: "OpenCode",
        trustProfile: .managed,
        securityProfileID: ServiceAgentProviderPolicyRegistry.controlledReadOnlyProfileID,
        existingPaths: existingPaths,
        environment: environment,
        allowInstallationSearch: discoveredExecutablePath == nil
      )
    case .antigravity:
      return try commandLineRequests(
        providerID: providerID,
        names: ["agy", "antigravity"],
        displayName: "Antigravity",
        trustProfile: .userTrusted,
        securityProfileID: AgentProfileID(rawValue: "desktop-shared"),
        existingPaths: existingPaths,
        environment: environment,
        allowInstallationSearch: discoveredExecutablePath == nil
      )
    case .deepSeekHarness:
      var environment = environment
      if let discoveredExecutablePath {
        environment["CODEX_BRIDGE_DEEPSEEK_HARNESS_EXECUTABLE"] = discoveredExecutablePath
      }
      return try deepSeekRequests(
        dataPaths: dataPaths,
        existingInstallations: existingInstallations,
        preferGeneratedConfiguration: credentialsProvided,
        environment: environment,
        allowGeneratedConfiguration: allowGeneratedConfiguration
      )
    case .codex:
      return []
    default:
      return []
    }
  }

  static func commandLineRequests(
    providerID: AgentProviderID,
    names: [String],
    displayName: String,
    trustProfile: AgentTrustProfile,
    securityProfileID: AgentProfileID,
    existingPaths: [String],
    environment: [String: String],
    allowInstallationSearch: Bool = true
  ) throws -> [ServiceAgentRegistrationRequest] {
    let baseDirectories =
      allowInstallationSearch
      ? userAgentDirectories(environment: environment) : []
    let resolver = AgentExecutableResolver(
      environment: environment,
      additionalDirectories: baseDirectories,
      includeEnvironmentPath: allowInstallationSearch,
      includeUserDirectories: allowInstallationSearch
    )
    var paths = existingPaths
    if allowInstallationSearch {
      paths.append(contentsOf: names.compactMap { resolver.resolve($0) })
    }
    #if os(Windows)
      if allowInstallationSearch {
        let initialHasUsableCandidate = paths.contains { path in
          guard let canonical = canonicalExecutable(path) else { return false }
          return isCommandLineExecutable(canonical)
        }
        let searchResolver: AgentExecutableResolver
        if initialHasUsableCandidate {
          searchResolver = resolver
        } else {
          let directories = ServiceAgentWindowsInstallationSources.searchDirectories(
            names: names,
            environment: environment
          )
          searchResolver = AgentExecutableResolver(
            environment: environment,
            additionalDirectories: uniquePaths(baseDirectories + directories)
          )
          paths.append(contentsOf: names.compactMap { searchResolver.resolve($0) })
        }
        paths.append(
          contentsOf: names.flatMap {
            commandScriptCandidates(name: $0, resolver: searchResolver)
          })
      }
    #endif
    var seen = Set<String>()
    return try paths.compactMap { path in
      guard let canonical = canonicalExecutable(path),
        isCommandLineExecutable(canonical),
        seen.insert(pathKey(canonical)).inserted
      else { return nil }
      return try ServiceAgentRegistrationRequest(
        providerID: providerID,
        displayName: displayName,
        executablePath: canonical,
        trustProfile: trustProfile,
        securityProfileID: securityProfileID,
        enableOnSuccess: false
      )
    }
  }

  private static func userAgentDirectories(
    environment: [String: String]
  ) -> [String] {
    guard let home = homeDirectory(environment: environment) else { return [] }
    var directories = [
      pathJoin(home, ".opencode", "bin"),
      pathJoin(home, ".antigravity", "bin"),
      pathJoin(home, ".local", "bin"),
    ]
    #if os(Windows)
      directories.append(contentsOf: [
        pathJoin(home, ".bun", "bin"),
        pathJoin(home, "scoop", "shims"),
      ])
      if let appData = environmentValue("APPDATA", environment: environment) {
        directories.append(pathJoin(appData, "npm"))
      }
      if let local = environmentValue("LOCALAPPDATA", environment: environment) {
        directories.append(pathJoin(local, "Programs", "nodejs"))
      }
    #else
      directories.append(contentsOf: macOSAgentSearchDirectories(environment: environment))
    #endif
    return directories
  }

  #if os(Windows)
    private static func commandScriptCandidates(
      name: String,
      resolver: AgentExecutableResolver
    ) -> [String] {
      resolver.searchDirectories().flatMap { directory in
        [pathJoin(directory, "\(name).cmd"), pathJoin(directory, "\(name).bat")]
      }
    }
  #endif

  private static func canonicalExecutable(_ path: String) -> String? {
    guard let canonical = canonicalRegularFile(path) else { return nil }
    #if os(Windows)
      let lower = canonical.lowercased()
      guard
        lower.hasSuffix(".exe") || lower.hasSuffix(".com") || lower.hasSuffix(".cmd")
          || lower.hasSuffix(".bat")
      else { return nil }
    #endif
    return canonical
  }

  static func canonicalRegularFile(_ path: String) -> String? {
    guard AgentPathSemantics.isAbsolute(path), !path.contains("\0"),
      path.rangeOfCharacter(from: .controlCharacters) == nil
    else { return nil }
    let canonical = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    #if canImport(Darwin)
      var metadata = stat()
      guard stat(canonical, &metadata) == 0,
        metadata.st_mode & S_IFMT == S_IFREG
      else { return nil }
    #else
      var directory = ObjCBool(false)
      let attributes = try? FileManager.default.attributesOfItem(atPath: canonical)
      guard FileManager.default.fileExists(atPath: canonical, isDirectory: &directory),
        !directory.boolValue,
        attributes?[.type] as? FileAttributeType == .typeRegular
      else { return nil }
    #endif
    return AgentPathSemantics.canonicalPath(canonical)
  }

  private static func isCommandLineExecutable(_ path: String) -> Bool {
    #if os(Windows)
      return !isWindowsGUIExecutable(path)
    #else
      return true
    #endif
  }

  #if os(Windows)
    static func isWindowsGUIExecutable(_ path: String) -> Bool {
      guard path.lowercased().hasSuffix(".exe"),
        let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path))
      else { return false }
      defer { try? handle.close() }
      guard let data = try? handle.read(upToCount: 0x400), data.count >= 0x40 else {
        return false
      }
      let bytes = [UInt8](data)
      guard bytes[0] == 0x4D, bytes[1] == 0x5A else { return false }
      let offset =
        UInt32(bytes[0x3C]) | UInt32(bytes[0x3D]) << 8
        | UInt32(bytes[0x3E]) << 16 | UInt32(bytes[0x3F]) << 24
      let header = Int(offset)
      guard header >= 0, header + 94 <= bytes.count,
        bytes[header] == 0x50, bytes[header + 1] == 0x45,
        bytes[header + 2] == 0, bytes[header + 3] == 0
      else { return false }
      let subsystem = UInt16(bytes[header + 92]) | UInt16(bytes[header + 93]) << 8
      return subsystem == 2
    }
  #endif

  static func homeDirectory(environment: [String: String]) -> String? {
    #if os(Windows)
      return environmentValue("USERPROFILE", environment: environment)
        ?? environmentValue("HOME", environment: environment)
    #else
      return environmentValue("HOME", environment: environment)
        ?? FileManager.default.homeDirectoryForCurrentUser.path
    #endif
  }

  static func environmentValue(
    _ key: String,
    environment: [String: String]
  ) -> String? {
    guard
      let found = environment.first(where: {
        $0.key.caseInsensitiveCompare(key) == .orderedSame
      })?.value,
      !found.isEmpty,
      !found.contains("\0"),
      found.rangeOfCharacter(from: .controlCharacters) == nil
    else { return nil }
    return found
  }

  static func pathJoin(_ first: String, _ components: String...) -> String {
    var path = first
    let separator = AgentPathStyle.current == .windows ? "\\" : "/"
    for component in components {
      if !path.hasSuffix(separator) { path.append(separator) }
      path.append(component.replacingOccurrences(of: "/", with: separator))
    }
    return path
  }

  static func uniquePaths(_ paths: [String]) -> [String] {
    var seen = Set<String>()
    return paths.filter { seen.insert(pathKey($0)).inserted }
  }

  static func pathKey(_ path: String) -> String {
    AgentPathStyle.current == .windows ? path.lowercased() : path
  }
}
