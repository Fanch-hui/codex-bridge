import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

struct MessageCenterNoticeResponse: Decodable, Sendable {
  let notices: [MessageCenterNoticeRecord]
  let hasMore: Bool?
  let nextCursor: String?
}

struct MessageCenterFeedbackResponse: Decodable {
  let feedback: MessageCenterFeedbackRecord
}

struct MessageCenterAttachmentResponse: Decodable {
  let attachment: MessageCenterAttachment
}

private struct MessageCenterServiceError: Decodable {
  struct Detail: Decodable {
    let code: String
    let message: String
  }
  let error: Detail
}

struct MessageCenterAttachmentReference: Encodable, Sendable {
  let id: String
}

struct MessageCenterCreateRequest: Encodable, Sendable {
  let requestId: String
  let category: String
  let body: String
  let appVersion: String
  let platform: String
  let attachments: [MessageCenterAttachmentReference]
}

struct MessageCenterReplyRequest: Encodable, Sendable {
  let requestId: String
  let body: String
  let attachments: [MessageCenterAttachmentReference]
}

enum MessageCenterClientError: Error, LocalizedError {
  case invalidResponse
  case httpStatus(Int)
  case service(code: String, message: String)
  case oversizedResponse

  var errorDescription: String? {
    switch self {
    case .invalidResponse: "消息中心返回的数据无效。"
    case .httpStatus(let status): "消息中心请求失败（HTTP \(status)）。"
    case .service(_, let message): message
    case .oversizedResponse: "消息中心返回的数据超过大小限制。"
    }
  }
}

struct MessageCenterClient: Sendable {
  static let defaultBaseURL = URL(
    string: "https://codex-bridge-message-center.canhuifan6.chatgpt.site")!
  private let baseURL: URL
  private let session: URLSession

  init(baseURL: URL = Self.defaultBaseURL, session: URLSession? = nil) {
    self.baseURL = baseURL
    self.session =
      session
      ?? URLSession(
        configuration: .ephemeral,
        delegate: MessageCenterRedirectGuard(origin: baseURL), delegateQueue: nil)
  }

  func notices(platform: String, version: String, cursor: String? = nil) async throws
    -> MessageCenterNoticeResponse
  {
    var components = URLComponents(url: endpoint("notices"), resolvingAgainstBaseURL: false)!
    components.queryItems = [
      URLQueryItem(name: "platform", value: platform),
      URLQueryItem(name: "version", value: version),
    ]
    if let cursor { components.queryItems?.append(URLQueryItem(name: "cursor", value: cursor)) }
    let (data, _) = try await perform(URLRequest(url: components.url!), maximumBytes: 1_048_576)
    let page = try JSONDecoder().decode(MessageCenterNoticeResponse.self, from: data)
    guard page.notices.count <= 50,
      (page.hasMore ?? false) == (page.nextCursor != nil),
      page.nextCursor.map({ !$0.isEmpty && $0.utf8.count <= 1_024 }) ?? true
    else { throw MessageCenterClientError.invalidResponse }
    return page
  }

  func feedback(id: String, token: String) async throws -> MessageCenterFeedbackRecord {
    let (data, _) = try await perform(
      authorized("feedback/\(id)", token: token), maximumBytes: 2_097_152)
    return try JSONDecoder().decode(MessageCenterFeedbackResponse.self, from: data).feedback
  }

  func create(_ payload: MessageCenterCreateRequest, token: String) async throws
    -> MessageCenterFeedbackRecord
  {
    try await post("feedback", payload: payload, token: token)
  }

  func reply(id: String, _ payload: MessageCenterReplyRequest, token: String) async throws
    -> MessageCenterFeedbackRecord
  {
    try await post("feedback/\(id)/messages", payload: payload, token: token)
  }

  func upload(_ attachment: MessageCenterDraftAttachment, bytes: Data, token: String) async throws {
    var request = authorized("attachments/\(attachment.id)", token: token)
    request.httpMethod = "PUT"
    request.setValue(attachment.contentType, forHTTPHeaderField: "Content-Type")
    request.setValue(
      attachment.name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
      forHTTPHeaderField: "X-Filename")
    request.httpBody = bytes
    let (data, _) = try await perform(request, maximumBytes: 16_384)
    let result = try JSONDecoder().decode(MessageCenterAttachmentResponse.self, from: data)
      .attachment
    guard result.id == attachment.id, result.size == attachment.size,
      result.contentType == attachment.contentType
    else { throw MessageCenterClientError.invalidResponse }
  }

  func download(id: String, token: String) async throws -> (Data, String?) {
    let (data, response) = try await perform(
      authorized("attachments/\(id)", token: token), maximumBytes: 10 * 1_024 * 1_024)
    return (data, response.value(forHTTPHeaderField: "Content-Type"))
  }

  private func post<T: Encodable>(_ path: String, payload: T, token: String) async throws
    -> MessageCenterFeedbackRecord
  {
    var request = authorized(path, token: token)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder().encode(payload)
    let (data, _) = try await perform(request, maximumBytes: 2_097_152)
    return try JSONDecoder().decode(MessageCenterFeedbackResponse.self, from: data).feedback
  }

  private func endpoint(_ path: String) -> URL {
    baseURL.appendingPathComponent("api/v1").appendingPathComponent(path)
  }

  private func authorized(_ path: String, token: String) -> URLRequest {
    var request = URLRequest(url: endpoint(path))
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    return request
  }

  private func perform(_ original: URLRequest, maximumBytes: Int) async throws -> (
    Data, HTTPURLResponse
  ) {
    var request = original
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.setValue("CodexBridge", forHTTPHeaderField: "User-Agent")
    request.timeoutInterval = 30
    let (data, response) = try await session.data(for: request)
    guard let response = response as? HTTPURLResponse else {
      throw MessageCenterClientError.invalidResponse
    }
    guard (200..<300).contains(response.statusCode) else {
      if data.count <= 16_384,
        let detail = try? JSONDecoder().decode(MessageCenterServiceError.self, from: data).error,
        [
          "invalid_request", "unauthorized", "forbidden", "not_found", "conflict", "too_large",
          "rate_limited", "unavailable", "internal_error",
        ].contains(detail.code),
        !detail.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        detail.message.utf8.count <= 1_024
      {
        throw MessageCenterClientError.service(code: detail.code, message: detail.message)
      }
      throw MessageCenterClientError.httpStatus(response.statusCode)
    }
    guard data.count <= maximumBytes else { throw MessageCenterClientError.oversizedResponse }
    return (data, response)
  }
}

private final class MessageCenterRedirectGuard: NSObject, URLSessionTaskDelegate,
  @unchecked Sendable
{
  private let origin: URL

  init(origin: URL) { self.origin = origin }

  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    guard let url = request.url,
      url.scheme?.lowercased() == origin.scheme?.lowercased(),
      url.host?.lowercased() == origin.host?.lowercased(),
      url.port == origin.port
    else {
      completionHandler(nil)
      return
    }
    completionHandler(request)
  }
}
