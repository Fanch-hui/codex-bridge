import Foundation

public struct MessageCenterState: Codable, Equatable, Sendable {
  public var appVersion = ""
  public var platform = ""
  public var unreadCount = 0
  public var isRefreshing = false
  public var hasMoreNotices = false
  public var error: String?
  public var notices: [MessageCenterNotice] = []
  public var feedbacks: [MessageCenterFeedback] = []
  public var isSubmitting = false
  public var submissionError: String?
  public var submissionAttemptID: String?
  public var submissionReceipt: MessageCenterSubmissionReceipt?
  public var draftAttachments: [MessageCenterDraftAttachment] = []

  public init() {}
}

public struct MessageCenterNoticeAction: Codable, Equatable, Sendable {
  public let kind: String
  public let label: String
  public let url: String?
}

public struct MessageCenterNotice: Codable, Equatable, Sendable {
  public let id: String
  public let title: String
  public let body: String
  public let priority: String
  public let revision: Int
  public let publishedAt: String
  public let updatedAt: String
  public let expiresAt: String?
  public let action: MessageCenterNoticeAction?
  public var isRead: Bool
}

public struct MessageCenterAttachment: Codable, Equatable, Sendable {
  public let id: String
  public let name: String
  public let contentType: String
  public let size: Int
}

public struct MessageCenterMessage: Codable, Equatable, Sendable {
  public let id: String
  public let author: String
  public let body: String
  public let createdAt: String
  public let attachments: [MessageCenterAttachment]?
}

public struct MessageCenterFeedback: Codable, Equatable, Sendable {
  public let id: String
  public let category: String
  public let status: String
  public let createdAt: String
  public let updatedAt: String
  public let messages: [MessageCenterMessage]
  public var unreadCount: Int
}

public struct MessageCenterDraftAttachment: Codable, Equatable, Sendable {
  public let id: String
  public let name: String
  public let contentType: String
  public let size: Int
  public let feedbackID: String?
}

public struct MessageCenterSubmissionReceipt: Codable, Equatable, Sendable {
  public let kind: String
  public let id: String
  public let requestID: String
}

struct MessageCenterNoticeRecord: Codable, Equatable, Sendable {
  let id: String
  let title: String
  let body: String
  let priority: String
  let revision: Int
  let publishedAt: String
  let updatedAt: String
  let expiresAt: String?
  let action: MessageCenterNoticeAction?

  func presentation(isRead: Bool) -> MessageCenterNotice {
    MessageCenterNotice(
      id: id, title: title, body: body, priority: priority, revision: revision,
      publishedAt: publishedAt, updatedAt: updatedAt, expiresAt: expiresAt, action: action,
      isRead: isRead)
  }
}

struct MessageCenterFeedbackRecord: Codable, Equatable, Sendable {
  let id: String
  let category: String
  let status: String
  let createdAt: String
  let updatedAt: String
  let messages: [MessageCenterMessage]

  func presentation(seenMessages: Set<String>) -> MessageCenterFeedback {
    MessageCenterFeedback(
      id: id, category: category, status: status, createdAt: createdAt, updatedAt: updatedAt,
      messages: messages,
      unreadCount: messages.filter { $0.author == "admin" && !seenMessages.contains($0.id) }.count)
  }
}
