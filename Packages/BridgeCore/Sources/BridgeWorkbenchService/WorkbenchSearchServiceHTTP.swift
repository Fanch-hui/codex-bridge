import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

enum WorkbenchSearchHTTPClient {
  static let maximumResponseBytes = 1_024 * 1_024

  static func send(_ request: URLRequest) async throws -> (Data, Int) {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.urlCache = nil
    configuration.httpCookieStorage = nil
    configuration.urlCredentialStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.timeoutIntervalForRequest = request.timeoutInterval
    configuration.timeoutIntervalForResource = request.timeoutInterval
    let delegate = Delegate()
    let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    let task = session.dataTask(with: request)
    defer { session.invalidateAndCancel() }
    return try await withTaskCancellationHandler {
      try await delegate.start(task: task)
    } onCancel: {
      delegate.cancel(task: task)
    }
  }

  // URLSession serializes callbacks on its delegate queue.
  private final class Delegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<(Data, Int), Error>?
    private var result: Result<(Data, Int), Error>?
    private var content = Data()
    private var status: Int?

    func start(task: URLSessionDataTask) async throws -> (Data, Int) {
      try await withCheckedThrowingContinuation { continuation in
        lock.lock()
        if let result {
          lock.unlock()
          continuation.resume(with: result)
          return
        }
        self.continuation = continuation
        lock.unlock()
        task.resume()
      }
    }

    func cancel(task: URLSessionTask) {
      finish(.failure(CancellationError()))
      task.cancel()
    }

    func urlSession(
      _ session: URLSession, task: URLSessionTask,
      willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
      completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
      completionHandler(nil)
    }

    func urlSession(
      _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
      completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
      guard let http = response as? HTTPURLResponse else {
        finish(.failure(invalidResponse()))
        completionHandler(.cancel)
        return
      }
      status = http.statusCode
      guard response.expectedContentLength <= Int64(WorkbenchSearchHTTPClient.maximumResponseBytes)
      else {
        finish(.failure(invalidResponse()))
        completionHandler(.cancel)
        return
      }
      completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
      guard data.count <= WorkbenchSearchHTTPClient.maximumResponseBytes - content.count else {
        finish(.failure(invalidResponse()))
        dataTask.cancel()
        return
      }
      content.append(data)
    }

    func urlSession(
      _ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?
    ) {
      if let error {
        finish(.failure(error))
      } else if let status {
        finish(.success((content, status)))
      } else {
        finish(.failure(invalidResponse()))
      }
    }

    private func invalidResponse() -> WorkbenchSearchError {
      WorkbenchSearchError(
        code: "workbench_search_invalid_response", message: "搜索服务返回的数据无效或过大。",
        retryable: true)
    }

    private func finish(_ result: Result<(Data, Int), Error>) {
      lock.lock()
      guard self.result == nil else {
        lock.unlock()
        return
      }
      self.result = result
      let continuation = self.continuation
      self.continuation = nil
      lock.unlock()
      continuation?.resume(with: result)
    }
  }
}
