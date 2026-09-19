import Darwin
import Foundation

enum MacAppUpdateServiceExit {
  static func processIDs() async throws -> [Int32] {
    try await Task.detached {
      let process = Process()
      let output = Pipe()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
      process.arguments = [
        "-f", "^/Applications/CodexBridge\\.app/Contents/Resources/CodexBridgeService$",
      ]
      process.standardOutput = output
      process.standardError = FileHandle.nullDevice
      try process.run()
      let data = output.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()
      guard process.terminationStatus == 0 || process.terminationStatus == 1 else {
        throw MacAppUpdateError.message("无法检查后台服务退出状态，请重试。")
      }
      return String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline)
        .compactMap { Int32($0) }.filter { $0 > 1 }
    }.value
  }

  static func wait(for pids: [Int32]) async throws {
    for _ in 0..<300 {
      let exited = pids.allSatisfy { kill($0, 0) != 0 && errno == ESRCH }
      if exited { return }
      try await Task.sleep(for: .milliseconds(100))
    }
    throw MacAppUpdateError.message("后台服务尚未退出，更新已取消，请稍后重试。")
  }
}
