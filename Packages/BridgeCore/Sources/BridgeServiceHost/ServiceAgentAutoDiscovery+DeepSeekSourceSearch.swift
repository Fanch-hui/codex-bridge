import BridgeAgentCore
import Foundation

#if canImport(Darwin)
  import Darwin
#endif

#if os(Windows)
  import WinSDK
#endif

/// Finds an unregistered DSH source checkout without making its location part of
/// the product configuration. The search is deliberately bounded because it can
/// run while the service prepares the first connection snapshot.
enum ServiceAgentDeepSeekSourceSearch {
  struct Limits: Sendable {
    let maximumDirectories: Int
    let maximumDepth: Int
    let maximumMilliseconds: Int

    static let startup = Limits(
      maximumDirectories: 2_048,
      maximumDepth: 6,
      maximumMilliseconds: 2_000
    )
  }

  private struct SearchAnchor {
    let path: String
    let restrictFirstLevel: Bool
  }

  private static let developmentDirectoryNames: Set<String> = [
    "code", "codes", "dev", "development", "develop", "documents", "projects", "project",
    "repos", "repo", "src", "source", "work", "workspace", "workspaces",
  ]

  private static let excludedDirectoryNames: Set<String> = [
    ".git", ".hg", ".svn", "node_modules", ".pnpm-store", ".npm", ".yarn", ".bun",
    ".cache", "cache", "caches", "library", "appdata", "programdata", "windows",
    "$recycle.bin", "system volume information", "build", "dist", "deriveddata",
  ]

  static func discover(
    environment: [String: String],
    limits: Limits = .startup,
    fileManager: FileManager = .default,
    now: () -> Date = Date.init,
    anchors: [String]? = nil
  ) -> [String] {
    let deadline = now().addingTimeInterval(Double(limits.maximumMilliseconds) / 1_000)
    var directoriesVisited = 0
    var results: [String] = []
    var seenRoots = Set<String>()

    let searchAnchors =
      anchors.map {
        $0.map { SearchAnchor(path: $0, restrictFirstLevel: false) }
      } ?? searchAnchors(environment: environment, fileManager: fileManager)
    let anchorBudget = max(
      100,
      limits.maximumMilliseconds / max(1, searchAnchors.count)
    )

    for anchor in searchAnchors {
      guard directoriesVisited < limits.maximumDirectories, now() < deadline else { break }
      let anchorDeadline = min(
        deadline,
        now().addingTimeInterval(Double(anchorBudget) / 1_000)
      )
      let anchorLimits = Limits(
        maximumDirectories: min(
          limits.maximumDirectories,
          directoriesVisited + max(1, limits.maximumDirectories / max(1, searchAnchors.count))
        ),
        maximumDepth: limits.maximumDepth,
        maximumMilliseconds: anchorBudget
      )
      search(
        anchor: anchor.path,
        restrictFirstLevel: anchor.restrictFirstLevel,
        limits: anchorLimits,
        deadline: anchorDeadline,
        fileManager: fileManager,
        now: now,
        directoriesVisited: &directoriesVisited,
        results: &results,
        seenRoots: &seenRoots
      )
      if !results.isEmpty { break }
    }
    return results
  }

  private static func search(
    anchor: String,
    restrictFirstLevel: Bool,
    limits: Limits,
    deadline: Date,
    fileManager: FileManager,
    now: () -> Date,
    directoriesVisited: inout Int,
    results: inout [String],
    seenRoots: inout Set<String>
  ) {
    guard safeDirectory(anchor, fileManager: fileManager) else { return }
    if isDeepSeekSourceRoot(anchor, fileManager: fileManager),
      seenRoots.insert(
        pathKey(anchor)
      ).inserted
    {
      results.append(anchor)
      return
    }
    let anchorURL = URL(fileURLWithPath: anchor, isDirectory: true)
    guard
      let enumerator = fileManager.enumerator(
        at: anchorURL,
        includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
        options: [.skipsHiddenFiles, .skipsPackageDescendants]
      )
    else { return }

    let anchorComponents = anchorURL.standardizedFileURL.pathComponents
    while let item = enumerator.nextObject() as? URL {
      guard directoriesVisited < limits.maximumDirectories, now() < deadline else { break }
      guard
        let values = try? item.resourceValues(
          forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        )
      else { continue }
      let path = item.standardizedFileURL.path
      let components = item.standardizedFileURL.pathComponents
      let depth = max(0, components.count - anchorComponents.count)

      if values.isSymbolicLink == true || isLinkOrReparsePoint(path) {
        if values.isDirectory == true { enumerator.skipDescendants() }
        continue
      }
      if values.isDirectory == true {
        directoriesVisited += 1
        if depth <= limits.maximumDepth,
          isDeepSeekSourceRoot(path, fileManager: fileManager),
          seenRoots.insert(
            pathKey(path)
          ).inserted
        {
          results.append(path)
          // A source root contains the complete layout we need. Do not spend
          // the remaining budget walking its dependencies or build outputs.
          enumerator.skipDescendants()
          continue
        }
        if depth >= limits.maximumDepth
          || shouldSkipDirectory(
            item.lastPathComponent,
            depth: depth,
            restrictFirstLevel: restrictFirstLevel
          )
        {
          enumerator.skipDescendants()
        }
        continue
      }
    }
  }

  private static func searchAnchors(
    environment: [String: String],
    fileManager: FileManager
  ) -> [SearchAnchor] {
    var anchors: [SearchAnchor] = []
    if let home = ServiceAgentAutoDiscovery.homeDirectory(environment: environment) {
      anchors.append(SearchAnchor(path: home, restrictFirstLevel: true))
    }

    #if os(Windows)
      anchors.append(
        contentsOf: fixedWindowsDevelopmentAnchors(fileManager: fileManager).map {
          SearchAnchor(path: $0, restrictFirstLevel: false)
        })
    #else
      anchors.append(
        contentsOf: localVolumeDevelopmentAnchors(fileManager: fileManager).map {
          SearchAnchor(path: $0, restrictFirstLevel: false)
        })
    #endif

    var seen = Set<String>()
    return anchors.filter { seen.insert(pathKey($0.path)).inserted }
  }

  #if os(Windows)
    private static func fixedWindowsDevelopmentAnchors(fileManager: FileManager) -> [String] {
      var anchors: [String] = []
      var drives = GetLogicalDrives()
      var index: UInt32 = 0
      while drives != 0 {
        if drives & 1 != 0 {
          let letter = UnicodeScalar(65 + index).map(String.init) ?? ""
          let root = "\(letter):\\"
          if fixedWindowsDrive(root),
            let contents = try? fileManager.contentsOfDirectory(
              atPath: root
            )
          {
            anchors.append(
              contentsOf: contents.compactMap { name in
                let lower = name.lowercased()
                guard
                  developmentDirectoryNames.contains(lower)
                    || lower.contains("deepseek") || lower.contains("harness")
                else { return nil }
                return ServiceAgentAutoDiscovery.pathJoin(root, name)
              })
          }
        }
        drives >>= 1
        index += 1
      }
      return anchors
    }

    private static func fixedWindowsDrive(_ root: String) -> Bool {
      let type = root.withCString(encodedAs: UTF16.self) { GetDriveTypeW($0) }
      return type == UINT(DRIVE_FIXED)
    }
  #else
    private static func localVolumeDevelopmentAnchors(fileManager: FileManager) -> [String] {
      let keys: Set<URLResourceKey> = [.volumeIsLocalKey, .volumeIsRemovableKey]
      let volumes =
        fileManager.mountedVolumeURLs(
          includingResourceValuesForKeys: Array(keys),
          options: [.skipHiddenVolumes]
        ) ?? []
      return volumes.flatMap { volume -> [String] in
        guard let values = try? volume.resourceValues(forKeys: keys),
          values.volumeIsLocal == true,
          values.volumeIsRemovable != true
        else { return [String]() }
        return (try? fileManager.contentsOfDirectory(atPath: volume.path))?.compactMap { name in
          let lower = name.lowercased()
          guard
            developmentDirectoryNames.contains(lower)
              || lower.contains("deepseek") || lower.contains("harness")
          else { return nil }
          return ServiceAgentAutoDiscovery.pathJoin(volume.path, name)
        } ?? []
      }
    }
  #endif

  private static func shouldSkipDirectory(
    _ name: String,
    depth: Int,
    restrictFirstLevel: Bool
  ) -> Bool {
    let lower = name.lowercased()
    if excludedDirectoryNames.contains(lower) || lower.hasPrefix(".") { return true }
    // At the first level of a user home or a mounted volume, only development
    // roots and an obvious DSH checkout are useful search targets.
    if restrictFirstLevel && depth == 1 {
      return !developmentDirectoryNames.contains(lower)
        && !lower.contains("deepseek") && !lower.contains("harness")
    }
    return false
  }

  private static func isDeepSeekSourceRoot(_ path: String, fileManager: FileManager) -> Bool {
    let entry = ServiceAgentAutoDiscovery.pathJoin(path, "apps", "cli", "lib", "bin.js")
    guard regularFileWithoutLink(entry, fileManager: fileManager) else { return false }
    let manifest = ServiceAgentAutoDiscovery.pathJoin(path, "package.json")
    guard regularFileWithoutLink(manifest, fileManager: fileManager),
      manifestIdentifiesDeepSeek(manifest)
    else { return false }
    return ["pnpm-lock.yaml", "package-lock.json", "npm-shrinkwrap.json"].contains {
      regularFileWithoutLink(
        ServiceAgentAutoDiscovery.pathJoin(path, $0),
        fileManager: fileManager
      )
    }
  }

  private static func manifestIdentifiesDeepSeek(_ path: String) -> Bool {
    guard let data = boundedRead(path, maximumBytes: 256 * 1_024),
      let object = try? JSONSerialization.jsonObject(with: data),
      let manifest = object as? [String: Any]
    else { return false }

    let acceptedNames: Set<String> = [
      "deepseek-harness", "@deepseek-ai/deepseek-harness", "@deepseek-ai/dsh",
      "@deepseek-ai/dsh-root",
    ]
    if let name = manifest["name"] as? String, acceptedNames.contains(name.lowercased()) {
      return true
    }
    let repositoryText = repositoryValue(manifest["repository"])
    return repositoryText.contains("deepseek-ai/deepseek-harness")
  }

  private static func boundedRead(_ path: String, maximumBytes: Int) -> Data? {
    guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else {
      return nil
    }
    defer { try? handle.close() }
    guard let data = try? handle.read(upToCount: maximumBytes + 1),
      data.count <= maximumBytes
    else { return nil }
    return data
  }

  private static func repositoryValue(_ value: Any?) -> String {
    if let text = value as? String { return text.lowercased() }
    if let object = value as? [String: Any] {
      return object.values.compactMap { $0 as? String }.joined(separator: " ").lowercased()
    }
    return ""
  }

  private static func regularFileWithoutLink(_ path: String, fileManager: FileManager) -> Bool {
    guard !isLinkOrReparsePoint(path),
      let values = try? URL(fileURLWithPath: path)
        .resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    else { return false }
    return values.isRegularFile == true && values.isSymbolicLink != true
  }

  private static func safeDirectory(_ path: String, fileManager: FileManager) -> Bool {
    guard !isLinkOrReparsePoint(path),
      let values = try? URL(fileURLWithPath: path)
        .resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    else { return false }
    return values.isDirectory == true && values.isSymbolicLink != true
  }

  private static func pathKey(_ path: String) -> String {
    AgentPathStyle.current == .windows ? path.lowercased() : path
  }

  private static func isLinkOrReparsePoint(_ path: String) -> Bool {
    #if os(Windows)
      let attributes = path.withCString(encodedAs: UTF16.self) { GetFileAttributesW($0) }
      return attributes != INVALID_FILE_ATTRIBUTES
        && attributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT) != 0
    #elseif canImport(Darwin)
      var metadata = stat()
      return lstat(path, &metadata) == 0 && metadata.st_mode & S_IFMT == S_IFLNK
    #else
      return
        (try? URL(fileURLWithPath: path).resourceValues(
          forKeys: [.isSymbolicLinkKey]
        ).isSymbolicLink) == true
    #endif
  }
}
