import Crypto
import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

public final class AppUpdateClient: AppUpdateClientProtocol, @unchecked Sendable {
  public static let feedURL = URL(
    string: "https://github.com/Fanch-hui/codex-bridge/releases/latest/download/latest.json"
  )!

  private static let releasePathPrefix = "/Fanch-hui/codex-bridge/releases/download/"
  private let session: URLSession

  public init() {
    session = .shared
  }

  init(session: URLSession) {
    self.session = session
  }

  public func check(
    currentVersion: String,
    platform: String,
    architecture: String,
    kind: String
  ) async throws -> AppUpdateRelease? {
    let current = try AppUpdateVersion(currentVersion)
    var request = URLRequest(url: Self.feedURL)
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.timeoutInterval = 20
    let (data, response) = try await session.data(for: request)
    guard let response = response as? HTTPURLResponse else {
      throw AppUpdateError.invalidManifest
    }
    guard (200..<300).contains(response.statusCode) else {
      throw AppUpdateError.httpStatus(response.statusCode)
    }

    let manifest: AppUpdateManifest
    do {
      manifest = try JSONDecoder().decode(AppUpdateManifest.self, from: data)
    } catch {
      throw AppUpdateError.invalidManifest
    }
    return try Self.selectRelease(
      manifest: manifest,
      currentVersion: current,
      platform: platform,
      architecture: architecture,
      kind: kind
    )
  }

  public func download(
    _ release: AppUpdateRelease,
    progress: @escaping @Sendable (Double) -> Void
  ) async throws -> URL {
    try Self.validateAsset(release.asset)
    let stagingDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("CodexBridgeUpdate-\(UUID().uuidString)", isDirectory: true)
    let destination = stagingDirectory.appendingPathComponent(Self.fileName(for: release.asset.url))

    do {
      try FileManager.default.createDirectory(
        at: stagingDirectory,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
      )
      let request = URLRequest(url: release.asset.url)
      guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
        throw AppUpdateError.invalidManifest
      }
      let result = try await AppUpdateDownload.run(
        request: request,
        destination: destination,
        progress: progress
      )
      try AppUpdateIntegrity.validate(
        size: result.size,
        digest: result.digest,
        expectedSize: release.asset.size,
        expectedDigest: release.asset.sha256
      )
      progress(1)
      return destination
    } catch {
      try? FileManager.default.removeItem(at: stagingDirectory)
      throw error
    }
  }

  static func selectRelease(
    manifest: AppUpdateManifest,
    currentVersion: AppUpdateVersion,
    platform: String,
    architecture: String,
    kind: String
  ) throws -> AppUpdateRelease? {
    try validateManifest(manifest)
    let releaseVersion = try AppUpdateVersion(manifest.version)
    guard releaseVersion > currentVersion else { return nil }

    let matches = manifest.assets.filter {
      $0.platform == platform && $0.architecture == architecture && $0.kind == kind
    }
    guard !matches.isEmpty else { throw AppUpdateError.noMatchingAsset }
    guard matches.count == 1, let asset = matches.first else {
      throw AppUpdateError.ambiguousAssets
    }
    return AppUpdateRelease(manifest: manifest, asset: asset)
  }

  static func selectRelease(
    manifest: AppUpdateManifest,
    currentVersion: String,
    platform: String,
    architecture: String,
    kind: String
  ) throws -> AppUpdateRelease? {
    let current = try AppUpdateVersion(currentVersion)
    return try selectRelease(
      manifest: manifest,
      currentVersion: current,
      platform: platform,
      architecture: architecture,
      kind: kind
    )
  }

  static func validateManifest(_ manifest: AppUpdateManifest) throws {
    _ = try AppUpdateVersion(manifest.version)
    guard !manifest.assets.isEmpty else { throw AppUpdateError.invalidManifest }
    for asset in manifest.assets {
      try validateAsset(asset)
    }
  }

  static func validateAsset(_ asset: AppUpdateAsset) throws {
    guard ["macos", "windows"].contains(asset.platform),
      ["arm64", "x64"].contains(asset.architecture),
      ["app", "installer", "portable"].contains(asset.kind),
      asset.size >= 0,
      AppUpdateIntegrity.isSHA256(asset.sha256),
      isReleaseURL(asset.url)
    else {
      if !isReleaseURL(asset.url) { throw AppUpdateError.invalidAssetURL }
      throw AppUpdateError.invalidAsset
    }
  }

  private static func isReleaseURL(_ url: URL) -> Bool {
    guard url.scheme?.lowercased() == "https",
      url.host?.lowercased() == "github.com",
      url.port == nil,
      url.user == nil,
      url.password == nil,
      url.query == nil,
      url.fragment == nil
    else { return false }
    guard url.path.hasPrefix(Self.releasePathPrefix) else { return false }
    let assetPath = String(url.path.dropFirst(Self.releasePathPrefix.count))
    return !assetPath.isEmpty && !assetPath.hasSuffix("/")
  }

  private static func fileName(for url: URL) -> String {
    let lastPathComponent = url.lastPathComponent
    guard !lastPathComponent.isEmpty, lastPathComponent != ".", lastPathComponent != ".." else {
      return "update-package"
    }
    return lastPathComponent
  }

}

struct AppUpdateVersion: Comparable, Sendable {
  let components: [Int]

  init(_ value: String) throws {
    let parts = value.split(separator: ".", omittingEmptySubsequences: false)
    let numericParts = parts.compactMap { Int($0) }
    guard parts.count == 3,
      parts.allSatisfy({ part in
        !part.isEmpty && (part == "0" || !part.hasPrefix("0")) && part.allSatisfy { $0.isNumber }
      }),
      numericParts.count == parts.count
    else {
      throw AppUpdateError.invalidVersion(value)
    }
    self.components = numericParts
  }

  static func < (lhs: AppUpdateVersion, rhs: AppUpdateVersion) -> Bool {
    lhs.components.lexicographicallyPrecedes(rhs.components)
  }
}

enum AppUpdateIntegrity {
  static func isSHA256(_ value: String) -> Bool {
    value.count == 64
      && value.utf8.allSatisfy { byte in
        (48...57).contains(byte) || (97...102).contains(byte)
      }
  }

  static func validate(
    size: Int64,
    digest: String,
    expectedSize: Int64,
    expectedDigest: String
  ) throws {
    guard size == expectedSize else {
      throw AppUpdateError.sizeMismatch(expected: expectedSize, actual: size)
    }
    guard digest == expectedDigest else {
      throw AppUpdateError.checksumMismatch
    }
  }

  static func validate(
    fileURL: URL,
    expectedSize: Int64,
    expectedDigest: String
  ) throws {
    let handle = try FileHandle(forReadingFrom: fileURL)
    defer { handle.closeFile() }
    var hasher = SHA256()
    var size: Int64 = 0
    while let data = try handle.read(upToCount: 64 * 1024), !data.isEmpty {
      size += Int64(data.count)
      hasher.update(data: data)
    }
    let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
    try validate(
      size: size, digest: digest, expectedSize: expectedSize, expectedDigest: expectedDigest)
  }
}
