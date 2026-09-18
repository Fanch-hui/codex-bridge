import Darwin
import Foundation

public enum MacAppUpdateHelper {
  public static func runIfRequested() {
    let args = CommandLine.arguments
    guard args.dropFirst().first == "--apply-app-update" else { return }
    guard args.count == 6, let parent = Int32(args[2]), parent > 1 else { exit(64) }
    let staged = URL(fileURLWithPath: args[3]).standardizedFileURL
    let target = URL(fileURLWithPath: args[4]).standardizedFileURL
    let workspace = URL(fileURLWithPath: args[5]).standardizedFileURL
    guard target.path == "/Applications/CodexBridge.app",
      staged.deletingLastPathComponent() == target.deletingLastPathComponent(),
      staged.lastPathComponent.hasPrefix(".CodexBridge-update-"),
      staged.pathExtension == "app",
      FileManager.default.fileExists(atPath: staged.path)
    else { exit(64) }
    do {
      try Data().write(to: workspace.appendingPathComponent("ready"))
      guard waitForExit(parent) else { throw MacAppUpdateError.message("应用未能退出，更新已取消。") }
      try replace(staged: staged, target: target)
      try? FileManager.default.removeItem(at: staged)
      open(target)
      try? FileManager.default.removeItem(at: workspace)
      exit(0)
    } catch {
      try? FileManager.default.removeItem(at: staged)
      writeFailure(error.localizedDescription)
      open(target)
      try? FileManager.default.removeItem(at: workspace)
      exit(1)
    }
  }

  static var failureURL: URL {
    FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("org.codexbridge.CodexBridge", isDirectory: true)
      .appendingPathComponent("update-error.txt")
  }

  static func replace(staged: URL, target: URL) throws {
    let result = staged.path.withCString { source in
      target.path.withCString { destination in
        renameatx_np(AT_FDCWD, source, AT_FDCWD, destination, UInt32(RENAME_SWAP))
      }
    }
    guard result == 0 else {
      throw MacAppUpdateError.message("无法替换应用，请检查 /Applications 的写入权限后重试。")
    }
  }

  private static func waitForExit(_ pid: Int32) -> Bool {
    for _ in 0..<1200 {
      if kill(pid, 0) != 0 && errno == ESRCH { return true }
      Thread.sleep(forTimeInterval: 0.1)
    }
    return false
  }

  private static func open(_ app: URL) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = [app.path]
    try? process.run()
    process.waitUntilExit()
  }

  private static func writeFailure(_ message: String) {
    try? FileManager.default.createDirectory(
      at: failureURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? Data(message.utf8).write(to: failureURL, options: .atomic)
  }
}
