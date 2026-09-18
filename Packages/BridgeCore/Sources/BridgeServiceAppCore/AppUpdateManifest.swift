import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

public struct AppUpdateAsset: Codable, Equatable, Sendable {
  public let platform: String
  public let architecture: String
  public let kind: String
  public let url: URL
  public let sha256: String
  public let size: Int64

  public init(
    platform: String,
    architecture: String,
    kind: String,
    url: URL,
    sha256: String,
    size: Int64
  ) {
    self.platform = platform
    self.architecture = architecture
    self.kind = kind
    self.url = url
    self.sha256 = sha256
    self.size = size
  }
}

public struct AppUpdateManifest: Codable, Equatable, Sendable {
  public let version: String
  public let notes: String
  public let assets: [AppUpdateAsset]

  public init(version: String, notes: String, assets: [AppUpdateAsset]) {
    self.version = version
    self.notes = notes
    self.assets = assets
  }
}

public struct AppUpdateRelease: Equatable, Sendable {
  public let manifest: AppUpdateManifest
  public let asset: AppUpdateAsset

  public init(manifest: AppUpdateManifest, asset: AppUpdateAsset) {
    self.manifest = manifest
    self.asset = asset
  }
}

public enum AppUpdateError: Error, Equatable, Sendable {
  case invalidManifest
  case invalidVersion(String)
  case invalidAsset
  case invalidAssetURL
  case noMatchingAsset
  case ambiguousAssets
  case httpStatus(Int)
  case sizeMismatch(expected: Int64, actual: Int64)
  case checksumMismatch
}

extension AppUpdateError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .invalidManifest: return "更新信息无效"
    case .invalidVersion(let version): return "更新版本号无效：\(version)"
    case .invalidAsset: return "更新文件信息无效"
    case .invalidAssetURL: return "更新文件地址无效"
    case .noMatchingAsset: return "没有匹配当前平台的更新文件"
    case .ambiguousAssets: return "更新文件匹配不唯一"
    case .httpStatus(let status): return "更新服务器返回错误（HTTP \(status)）"
    case .sizeMismatch(let expected, let actual):
      return "更新文件大小校验失败（应为 \(expected) 字节，收到 \(actual) 字节）"
    case .checksumMismatch: return "更新文件完整性校验失败"
    }
  }
}

public protocol AppUpdateClientProtocol: Sendable {
  func check(
    currentVersion: String,
    platform: String,
    architecture: String,
    kind: String
  ) async throws -> AppUpdateRelease?

  func download(
    _ release: AppUpdateRelease,
    progress: @escaping @Sendable (Double) -> Void
  ) async throws -> URL
}
