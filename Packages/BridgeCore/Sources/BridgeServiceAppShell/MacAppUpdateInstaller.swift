import AppKit
import BridgeServiceAppCore
import Foundation

@MainActor
final class MacAppUpdateInstaller {
  private var stagedApp: URL?
  private var workspace: URL?
  private var helper: Process?
  private let destination = URL(fileURLWithPath: "/Applications/CodexBridge.app")

  func prepare(_ archive: URL, release: AppUpdateRelease) async throws {
    guard Bundle.main.bundleURL.standardizedFileURL == destination else {
      throw MacAppUpdateError.message("请先将 CodexBridge.app 安装到 /Applications，再使用内置更新。")
    }
    let root = archive.deletingLastPathComponent()
    workspace = root
    let extracted = root.appendingPathComponent("extracted", isDirectory: true)
    try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)
    try await Self.run(
      "/usr/bin/ditto", ["-x", "-k", archive.path, extracted.path],
      failureMessage: "更新包解压失败")
    let app = extracted.appendingPathComponent("CodexBridge.app", isDirectory: true)
    guard let bundle = Bundle(url: app),
      bundle.bundleIdentifier == Bundle.main.bundleIdentifier,
      bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        == release.manifest.version.trimmingCharacters(in: CharacterSet(charactersIn: "vV")),
      let executable = bundle.executableURL,
      FileManager.default.isExecutableFile(atPath: executable.path),
      FileManager.default.isExecutableFile(
        atPath: app.appendingPathComponent("Contents/Resources/CodexBridgeService").path)
    else { throw MacAppUpdateError.message("更新包中的应用标识、版本或程序文件不匹配。") }
    #if arch(arm64)
      let architecture = "arm64"
    #else
      let architecture = "x86_64"
    #endif
    try await Self.run(
      "/usr/bin/lipo", [executable.path, "-verify_arch", architecture],
      failureMessage: "更新包中的应用架构不匹配")
    try await Self.run(
      "/usr/bin/lipo",
      [
        app.appendingPathComponent("Contents/Resources/CodexBridgeService").path,
        "-verify_arch", architecture,
      ], failureMessage: "更新包中的服务架构不匹配")
    try await Self.run(
      "/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path],
      failureMessage: "更新包签名验证失败")
    let staged = destination.deletingLastPathComponent()
      .appendingPathComponent(".CodexBridge-update-\(UUID().uuidString).app")
    stagedApp = staged
    try await Self.run("/usr/bin/ditto", [app.path, staged.path])
    guard let currentExecutable = Bundle.main.executableURL else {
      throw MacAppUpdateError.message("无法找到当前应用的更新助手。")
    }
    let helperContents = root.appendingPathComponent("helper/Contents", isDirectory: true)
    try FileManager.default.createDirectory(at: helperContents, withIntermediateDirectories: true)
    try await Self.run(
      "/usr/bin/ditto",
      [
        currentExecutable.deletingLastPathComponent().path,
        helperContents.appendingPathComponent("MacOS").path,
      ])
    if let frameworks = Bundle.main.privateFrameworksURL,
      FileManager.default.fileExists(atPath: frameworks.path)
    {
      try await Self.run(
        "/usr/bin/ditto",
        [
          frameworks.path, helperContents.appendingPathComponent("Frameworks").path,
        ])
    }
  }

  func launch() async throws {
    guard let stagedApp, let workspace else {
      throw MacAppUpdateError.message("更新包尚未准备完成。")
    }
    let process = Process()
    process.executableURL = workspace.appendingPathComponent("helper/Contents/MacOS/CodexBridge")
    process.arguments = [
      "--apply-app-update", String(ProcessInfo.processInfo.processIdentifier),
      stagedApp.path, destination.path, workspace.path,
    ]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    helper = process
    let ready = workspace.appendingPathComponent("ready")
    for _ in 0..<50 {
      if FileManager.default.fileExists(atPath: ready.path) { return }
      guard process.isRunning else { break }
      try await Task.sleep(for: .milliseconds(100))
    }
    throw MacAppUpdateError.message("更新助手启动失败，请重试。")
  }

  func cancel() {
    helper?.terminate()
    helper = nil
    if let stagedApp { try? FileManager.default.removeItem(at: stagedApp) }
    self.stagedApp = nil
    workspace = nil
  }

  private static func run(
    _ executable: String, _ arguments: [String], failureMessage: String = "更新文件复制失败"
  ) async throws {
    try Task.checkCancellation()
    try await Task.detached {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: executable)
      process.arguments = arguments
      process.standardOutput = FileHandle.nullDevice
      process.standardError = FileHandle.nullDevice
      try process.run()
      process.waitUntilExit()
      guard process.terminationStatus == 0 else {
        throw MacAppUpdateError.message("\(failureMessage)（退出码 \(process.terminationStatus)）。")
      }
    }.value
    try Task.checkCancellation()
  }
}

enum MacAppUpdateError: Error, LocalizedError {
  case message(String)
  var errorDescription: String? {
    switch self {
    case .message(let message): message
    }
  }
}
