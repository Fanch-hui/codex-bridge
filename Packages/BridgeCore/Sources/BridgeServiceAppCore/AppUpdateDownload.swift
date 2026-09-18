import Crypto
import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

struct AppUpdateDownloadResult: Sendable {
  let size: Int64
  let digest: String
}

enum AppUpdateDownload {
  static func run(
    request: URLRequest,
    destination: URL,
    progress: @escaping @Sendable (Double) -> Void
  ) async throws -> AppUpdateDownloadResult {
    let delegate = DownloadDelegate(destination: destination, progress: progress)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    defer { session.finishTasksAndInvalidate() }
    return try await withTaskCancellationHandler {
      try await delegate.start(session: session, request: request)
    } onCancel: {
      session.invalidateAndCancel()
    }
  }

  private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let progress: @Sendable (Double) -> Void
    private var continuation: CheckedContinuation<AppUpdateDownloadResult, Error>?

    init(destination: URL, progress: @escaping @Sendable (Double) -> Void) {
      self.destination = destination
      self.progress = progress
    }

    func start(session: URLSession, request: URLRequest) async throws -> AppUpdateDownloadResult {
      try await withCheckedThrowingContinuation { continuation in
        self.continuation = continuation
        session.downloadTask(with: request).resume()
      }
    }

    func urlSession(
      _ session: URLSession,
      downloadTask: URLSessionDownloadTask,
      didWriteData bytesWritten: Int64,
      totalBytesWritten: Int64,
      totalBytesExpectedToWrite: Int64
    ) {
      guard totalBytesExpectedToWrite > 0 else { return }
      progress(min(1, max(0, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))))
    }

    func urlSession(
      _ session: URLSession,
      downloadTask: URLSessionDownloadTask,
      didFinishDownloadingTo location: URL
    ) {
      guard let response = downloadTask.response as? HTTPURLResponse else {
        finish(.failure(AppUpdateError.invalidManifest))
        return
      }
      guard (200..<300).contains(response.statusCode) else {
        finish(.failure(AppUpdateError.httpStatus(response.statusCode)))
        return
      }

      do {
        finish(.success(try Self.copyAndHash(from: location, to: destination)))
      } catch {
        finish(.failure(error))
      }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?)
    {
      if let error { finish(.failure(error)) }
    }

    private func finish(_ result: Result<AppUpdateDownloadResult, Error>) {
      guard let continuation else { return }
      self.continuation = nil
      continuation.resume(with: result)
    }

    private static func copyAndHash(from source: URL, to destination: URL) throws
      -> AppUpdateDownloadResult
    {
      let input = try FileHandle(forReadingFrom: source)
      defer { input.closeFile() }
      let output = try FileHandle(forWritingTo: destination)
      var outputClosed = false
      defer {
        if !outputClosed { output.closeFile() }
      }

      var hasher = SHA256()
      var size: Int64 = 0
      while let data = try input.read(upToCount: 64 * 1024), !data.isEmpty {
        output.write(data)
        hasher.update(data: data)
        size += Int64(data.count)
      }
      output.closeFile()
      outputClosed = true
      let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
      return AppUpdateDownloadResult(size: size, digest: digest)
    }
  }
}
