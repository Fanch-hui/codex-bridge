import Foundation

@main
struct VerifyManagedStdio {
  /// 检查空闲 stderr 时连续 stdout 能在子进程退出前交付。
  /// 无输入；成功打印检查结果，失败退出。示例：verify-managed-stdio.exe。
  static func main() throws {
    #if os(Windows)
      let delivered = DispatchSemaphore(value: 0)
      let lock = NSLock()
      // 输出仅在 lock 内读写，供 Sendable 回调收集分段数据。
      nonisolated(unsafe) var output = Data()
      let child = try ManagedStdioProcess(
        argv: [ProcessInfo.processInfo.environment["ComSpec"]!, "/d", "/s", "/c",
          "echo STDIO_FIRST & ping -n 2 127.0.0.1 >nul & echo STDIO_SECOND & ping -n 10 127.0.0.1 >nul"],
        workingDirectory: nil,
        environment: ProcessInfo.processInfo.environment,
        mergeStandardError: false,
        onStandardOutput: { data in
          lock.lock()
          defer { lock.unlock() }
          output.append(data)
          let text = String(decoding: output, as: UTF8.self)
          if text.contains("STDIO_FIRST") && text.contains("STDIO_SECOND") {
            delivered.signal()
          }
        }
      )
      let result = delivered.wait(timeout: .now() + .seconds(3))
      let running = child.isRunning
      _ = child.terminateAndWait()
      child.close()
      precondition(result == .success && running,
        "空闲 stderr 时 stdout 未在子进程退出前完成两次交付")
      print("空闲 stderr、连续 stdout 和退出清理检查通过。")
    #else
      fatalError("此检查仅适用于 Windows。")
    #endif
  }
}
