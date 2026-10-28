import BridgeMCP
import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

enum ChatAttachmentDownload {
  static func validatedURL(_ value: String) throws -> URL {
    guard value.utf8.count <= 16 * 1_024,
      let url = URL(string: value), url.scheme?.lowercased() == "https",
      url.host?.lowercased() == "files.oaiusercontent.com",
      url.port == nil || url.port == 443,
      url.user == nil, url.password == nil, url.fragment == nil,
      !url.path.isEmpty
    else { throw MCPChatFileImportError.unsupportedSource }
    return url
  }

  static func run(
    url: URL, deadline: ContinuousClock.Instant,
    configuration: URLSessionConfiguration = .ephemeral
  ) async throws -> Data {
    _ = try validatedURL(url.absoluteString)
    let remaining = ContinuousClock.now.duration(to: deadline)
    guard remaining > .zero else { throw CancellationError() }
    let timeout = min(
      60,
      Double(remaining.components.seconds)
        + Double(remaining.components.attoseconds) / 1_000_000_000_000_000_000)
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.urlCache = nil
    configuration.httpCookieStorage = nil
    configuration.urlCredentialStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.timeoutIntervalForRequest = timeout
    configuration.timeoutIntervalForResource = timeout
    let delegate = AttachmentDelegate()
    let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    var request = URLRequest(url: url, timeoutInterval: timeout)
    request.httpShouldHandleCookies = false
    return try await withTaskCancellationHandler {
      try Task.checkCancellation()
      return try await delegate.start(session: session, request: request)
    } onCancel: {
      session.invalidateAndCancel()
    }
  }

  // URLSession serializes callbacks on its delegate queue; start installs the continuation before resume.
  private final class AttachmentDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private var continuation: CheckedContinuation<Data, Error>?
    private var content = Data()
    private var redirectCount = 0

    func start(session: URLSession, request: URLRequest) async throws -> Data {
      try await withCheckedThrowingContinuation { continuation in
        self.continuation = continuation
        session.dataTask(with: request).resume()
      }
    }

    func urlSession(
      _ session: URLSession, task: URLSessionTask,
      willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
      completionHandler: @escaping (URLRequest?) -> Void
    ) {
      guard redirectCount < 3, let url = request.url,
        (try? ChatAttachmentDownload.validatedURL(url.absoluteString)) != nil
      else {
        finish(.failure(MCPChatFileImportError.unsupportedSource))
        completionHandler(nil)
        task.cancel()
        return
      }
      redirectCount += 1
      var redirected = URLRequest(url: url, timeoutInterval: request.timeoutInterval)
      redirected.httpShouldHandleCookies = false
      completionHandler(redirected)
    }

    func urlSession(
      _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
      completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
      guard let response = response as? HTTPURLResponse else {
        finish(.failure(MCPChatFileImportError.downloadFailed))
        completionHandler(.cancel)
        return
      }
      guard response.statusCode == 200 else {
        let error: MCPChatFileImportError =
          [401, 403, 404, 410].contains(response.statusCode)
          ? .expiredSource : .downloadFailed
        finish(.failure(error))
        completionHandler(.cancel)
        return
      }
      guard response.expectedContentLength <= Int64(MCPFileTransferLimits.maximumFileBytes) else {
        finish(.failure(MCPChatFileImportError.fileTooLarge))
        completionHandler(.cancel)
        return
      }
      completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
      guard data.count <= MCPFileTransferLimits.maximumFileBytes - content.count else {
        finish(.failure(MCPChatFileImportError.fileTooLarge))
        dataTask.cancel()
        return
      }
      content.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?)
    {
      if let error {
        let failure: any Error =
          (error as? URLError)?.code == .cancelled
          ? CancellationError() : MCPChatFileImportError.downloadFailed
        finish(.failure(failure))
      } else {
        finish(.success(content))
      }
    }

    private func finish(_ result: Result<Data, Error>) {
      guard let continuation else { return }
      self.continuation = nil
      continuation.resume(with: result)
    }
  }
}
