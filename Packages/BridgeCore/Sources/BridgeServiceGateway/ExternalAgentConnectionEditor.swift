import BridgeAgentCore
import BridgeProcess
import Foundation

public struct ExternalAgentConnectionEditor: Sendable {
  public let node: URL
  public let entry: URL

  public init(node: URL, entry: URL) {
    self.node = node
    self.entry = entry
  }

  public func call(_ input: Data) async throws -> Data {
    guard node.isFileURL, entry.isFileURL, input.count <= 4 * 1_024 * 1_024 else {
      throw ExternalAgentConnectionError.invalidConfiguration
    }
    let output = ExternalAgentConnectionEditorOutput()
    let inherited = ProcessInfo.processInfo.environment
    var environment: [String: String] = [:]
    for key in ["SystemRoot", "WINDIR", "TMPDIR", "TMP", "TEMP"] {
      #if os(Windows)
        if let value = AgentProviderEnvironment.environmentValue(key, source: inherited),
          !value.isEmpty, !value.contains("\0")
        {
          environment[key] = value
        }
      #else
        if let value = inherited[key] { environment[key] = value }
      #endif
    }
    let process = try ManagedStdioProcess(
      argv: [node.path, entry.path], workingDirectory: entry.deletingLastPathComponent().path,
      environment: environment, mergeStandardError: false,
      onStandardOutput: { output.append($0) })
    return try await withTaskCancellationHandler {
      do {
        try Task.checkCancellation()
        try process.writeStdin(input)
        process.closeStdin()
        let result = await ManagedProcessRunner(defaultTimeout: .seconds(15)).monitor(
          process: process)
        guard process.isProcessTreeStopped() else {
          throw ExternalAgentConnectionError.editorProcessStillRunning
        }
        try Task.checkCancellation()
        guard !result.timedOut,
          result.termination == .exited(0) || result.termination == .exited(1),
          let bytes = output.snapshot(), !bytes.isEmpty
        else {
          throw ExternalAgentConnectionError.editorUnavailable
        }
        return bytes
      } catch let operationError {
        let stopped = await Task.detached {
          process.terminateProcessTreeAndWait()
        }.value
        guard stopped else {
          Self.retainUntilStopped(process)
          throw ExternalAgentConnectionCleanupFailure(
            operation: .editor, operationError: operationError,
            cleanupError: ExternalAgentConnectionError.editorProcessStillRunning)
        }
        process.close()
        throw operationError
      }
    } onCancel: {
      process.terminateGroup()
    }
  }

  private static func retainUntilStopped(_ process: ManagedStdioProcess) {
    Task.detached {
      while !process.isProcessTreeStopped() {
        try? await Task.sleep(for: .seconds(1))
      }
      process.close()
    }
  }
}

private final class ExternalAgentConnectionEditorOutput: @unchecked Sendable {
  private let lock = NSLock()
  private var bytes = Data()
  private var exceeded = false

  func append(_ data: Data) {
    lock.lock()
    defer { lock.unlock() }
    guard bytes.count + data.count <= 8 * 1_024 * 1_024 else {
      exceeded = true
      return
    }
    bytes.append(data)
  }

  func snapshot() -> Data? {
    lock.lock()
    defer { lock.unlock() }
    return exceeded ? nil : bytes
  }
}
