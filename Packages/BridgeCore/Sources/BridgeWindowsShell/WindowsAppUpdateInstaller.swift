#if os(Windows)
  import BridgeServiceAppCore
  import Foundation
  import WinSDK

  public enum WindowsAppUpdateInstallerError: Error, LocalizedError, Sendable, Equatable {
    case unsupportedReleaseAsset
    case currentExecutableUnavailable
    case installationDirectoryUnavailable
    case packageUnavailable
    case packageSizeMismatch
    case helperLaunchFailed(Int32)
    case installerLaunchFailed(Int32)

    public var errorDescription: String? {
      switch self {
      case .unsupportedReleaseAsset:
        return "更新包与当前 Windows 架构或安装方式不匹配。"
      case .currentExecutableUnavailable:
        return "无法确定当前 Codex Bridge 可执行文件位置。"
      case .installationDirectoryUnavailable:
        return "无法确定 Codex Bridge 的安装目录。"
      case .packageUnavailable:
        return "更新包不存在或无法读取。"
      case .packageSizeMismatch:
        return "更新包大小与发布清单不一致。"
      case .helperLaunchFailed(let code):
        return "无法启动 Windows 更新助手（错误代码 \(code)）。"
      case .installerLaunchFailed(let code):
        return "无法启动 Codex Bridge 安装程序（错误代码 \(code)）。"
      }
    }
  }

  @MainActor
  public final class WindowsAppUpdateInstaller {
    public enum InstallationKind: String, Sendable {
      case installer
      case portable
    }

    static let applicationExecutableName = "codex-bridge-windows-app.exe"
    static let serviceExecutableName = "codex-bridge-service.exe"
    static let installerRegistryKey =
      "Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\{6F51B5A4-4C25-4E72-A8E5-93447D72D031}_is1"

    let fileManager: FileManager
    var updateDirectory: URL?
    var packageURL: URL?
    var packageKind: InstallationKind?
    var pendingRelease: AppUpdateRelease?

    public init(fileManager: FileManager = .default) {
      self.fileManager = fileManager
    }

    public var installationKind: InstallationKind {
      guard let currentDirectory = Self.currentExecutableDirectory() else { return .portable }
      guard let registeredDirectory = Self.registeredInstallDirectory() else { return .portable }
      guard Self.normalizedPath(currentDirectory) == Self.normalizedPath(registeredDirectory) else {
        return .portable
      }
      let marker = URL(fileURLWithPath: registeredDirectory).appendingPathComponent(
        "CodexBridgeControl.v1"
      )
      return fileManager.fileExists(atPath: marker.path) ? .installer : .portable
    }

    public static var architecture: String {
      let environment = ProcessInfo.processInfo.environment
      let value = environment["PROCESSOR_ARCHITEW6432"] ?? environment["PROCESSOR_ARCHITECTURE"]
      return value?.caseInsensitiveCompare("ARM64") == .orderedSame ? "arm64" : "x64"
    }

    public static var currentVersion: String {
      guard let executableDirectory = currentExecutableDirectory() else { return "0.0.0" }
      let infoURL = URL(fileURLWithPath: executableDirectory).appendingPathComponent(
        "BUILD-INFO.json")
      guard
        let data = try? Data(contentsOf: infoURL),
        let object = try? JSONSerialization.jsonObject(with: data),
        let values = object as? [String: Any],
        let version = values["appVersion"] as? String,
        !version.isEmpty
      else {
        return "0.0.0"
      }
      return version
    }

    public static var failureReceiptURL: URL {
      FileManager.default.temporaryDirectory.appendingPathComponent(
        "CodexBridgeUpdateFailure.json"
      )
    }

    public static func consumeFailureReceipt() -> String? {
      let url = failureReceiptURL
      guard
        let data = try? Data(contentsOf: url),
        let object = try? JSONSerialization.jsonObject(with: data),
        let values = object as? [String: Any],
        let message = values["message"] as? String,
        !message.isEmpty
      else {
        return nil
      }
      try? FileManager.default.removeItem(at: url)
      return message
    }

    public func preparePackage(_ url: URL, release: AppUpdateRelease) async throws {
      let kind = installationKind
      guard
        release.asset.platform.caseInsensitiveCompare("windows") == .orderedSame,
        release.asset.architecture.caseInsensitiveCompare(Self.architecture) == .orderedSame,
        release.asset.kind.caseInsensitiveCompare(kind.rawValue) == .orderedSame,
        url.isFileURL,
        url.pathExtension.caseInsensitiveCompare(kind == .installer ? "exe" : "zip")
          == .orderedSame,
        fileManager.fileExists(atPath: url.path)
      else {
        throw WindowsAppUpdateInstallerError.unsupportedReleaseAsset
      }

      let attributes = try fileManager.attributesOfItem(atPath: url.path)
      guard let fileSize = attributes[.size] as? NSNumber else {
        throw WindowsAppUpdateInstallerError.packageUnavailable
      }
      if fileSize.int64Value != release.asset.size {
        throw WindowsAppUpdateInstallerError.packageSizeMismatch
      }

      let directory = fileManager.temporaryDirectory.appendingPathComponent(
        "CodexBridgeUpdate-\(UUID().uuidString)", isDirectory: true)
      do {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        updateDirectory = directory
        packageURL = url
        packageKind = kind
        pendingRelease = release
        if kind == .portable {
          try await preparePortablePackage(packageURL: url, updateDirectory: directory)
        }
      } catch {
        try? fileManager.removeItem(at: directory)
        updateDirectory = nil
        packageURL = nil
        packageKind = nil
        pendingRelease = nil
        throw WindowsAppUpdateInstallerError.packageUnavailable
      }
    }

    public func installPackage() async throws {
      guard
        let packageURL,
        let packageKind,
        let updateDirectory,
        let pendingRelease
      else {
        throw WindowsAppUpdateInstallerError.packageUnavailable
      }
      switch packageKind {
      case .installer:
        try await launchInstaller(
          packageURL: packageURL,
          updateDirectory: updateDirectory,
          release: pendingRelease
        )
      case .portable:
        try await launchPortableHelper(updateDirectory: updateDirectory)
      }
      self.packageURL = nil
      self.packageKind = nil
      self.updateDirectory = nil
      self.pendingRelease = nil
    }

    public func cancelPackage() {
      guard let updateDirectory else { return }
      try? fileManager.removeItem(at: updateDirectory)
      packageURL = nil
      packageKind = nil
      self.updateDirectory = nil
      pendingRelease = nil
    }

    func applicationDirectory() -> URL? {
      switch installationKind {
      case .installer:
        guard let path = Self.registeredInstallDirectory() else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
      case .portable:
        guard let path = Self.currentExecutableDirectory() else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
      }
    }

    static func currentExecutableDirectory() -> String? {
      guard let path = currentExecutablePath() else { return nil }
      return URL(fileURLWithPath: path).deletingLastPathComponent().path
    }

    static func currentExecutablePath() -> String? {
      var buffer = [WCHAR](repeating: 0, count: 32_768)
      let length = GetModuleFileNameW(nil, &buffer, DWORD(buffer.count))
      guard length > 0, length < DWORD(buffer.count) else { return nil }
      return String(decoding: buffer.prefix(Int(length)), as: UTF16.self)
    }

    static func registeredInstallDirectory() -> String? {
      WindowsAppUpdateRegistry.stringValue(
        keyPath: installerRegistryKey,
        valueName: "InstallLocation"
      )
    }

    static func normalizedPath(_ path: String) -> String {
      URL(fileURLWithPath: path).standardizedFileURL.path
        .replacingOccurrences(of: "/", with: "\\")
        .trimmingCharacters(in: ["\\"])
        .lowercased()
    }
  }
#endif
