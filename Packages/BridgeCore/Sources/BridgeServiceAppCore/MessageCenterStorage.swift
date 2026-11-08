import BridgeSecurity
import Foundation

struct MessageCenterSavedFeedback: Codable, Sendable {
  var feedback: MessageCenterFeedbackRecord
  let secretReference: String
}

struct MessageCenterPendingSubmission: Codable, Sendable {
  let requestID: String
  let feedbackID: String?
  let category: String
  let body: String
  let secretReference: String
  let attachments: [MessageCenterDraftAttachment]
  var definitivelyRejected: Bool? = nil
}

struct MessageCenterSavedState: Codable, Sendable {
  var notices: [MessageCenterNoticeRecord] = []
  var feedbacks: [MessageCenterSavedFeedback] = []
  var readNotices: [String: Int] = [:]
  var readMessages: Set<String> = []
  var draftAttachments: [MessageCenterDraftAttachment] = []
  var pending: [String: MessageCenterPendingSubmission] = [:]
}

struct MessageCenterStorage: Sendable {
  let root: URL
  private var manager: FileManager { .default }

  init(root: URL? = nil) throws {
    if let root {
      self.root = root
    } else {
      #if os(Linux)
        let parent =
          ProcessInfo.processInfo.environment["XDG_DATA_HOME"]
          .flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil }
          ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share")
      #else
        let parent =
          FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
          ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            "Library/Application Support")
      #endif
      self.root = parent.appendingPathComponent("CodexBridge/MessageCenter", isDirectory: true)
    }
    try createDirectory(self.root)
    try createDirectory(self.root.appendingPathComponent("drafts", isDirectory: true))
    try createDirectory(self.root.appendingPathComponent("downloads", isDirectory: true))
  }

  func load() throws -> MessageCenterSavedState {
    let url = root.appendingPathComponent("state.json")
    guard manager.fileExists(atPath: url.path) else { return MessageCenterSavedState() }
    return try JSONDecoder().decode(MessageCenterSavedState.self, from: Data(contentsOf: url))
  }

  func save(_ state: MessageCenterSavedState) throws {
    let destination = root.appendingPathComponent("state.json")
    let temporary = root.appendingPathComponent("state-\(UUID().uuidString).tmp")
    do {
      try JSONEncoder().encode(state).write(to: temporary)
      try protect(temporary)
      try FileReplacement.publish(temporary, at: destination)
    } catch {
      try? manager.removeItem(at: temporary)
      throw error
    }
  }

  func addDraft(path: String, feedbackID: String?) throws -> MessageCenterDraftAttachment {
    let source = URL(fileURLWithPath: path)
    let metadata = try FileSystemEntryMetadata(at: source)
    guard metadata.isRegularFile,
      let size = metadata.fileSize, size > 0,
      size <= 10 * 1_024 * 1_024
    else { throw MessageCenterStorageError.invalidImage }
    let bytes = try Data(contentsOf: source, options: .mappedIfSafe)
    guard bytes.count == size, let type = imageContentType(bytes) else {
      throw MessageCenterStorageError.invalidImage
    }
    let id = UUID().uuidString.lowercased()
    let destination = draftURL(id: id)
    try bytes.write(to: destination, options: .withoutOverwriting)
    do { try protect(destination) } catch {
      try? manager.removeItem(at: destination)
      throw error
    }
    var name = source.lastPathComponent
    while name.utf8.count > 128 { name.removeLast() }
    return MessageCenterDraftAttachment(
      id: id, name: name,
      contentType: type, size: size, feedbackID: feedbackID)
  }

  func draftURL(id: String) -> URL {
    root.appendingPathComponent("drafts", isDirectory: true).appendingPathComponent(id)
  }

  func removeDraft(id: String) throws {
    let url = draftURL(id: id)
    if manager.fileExists(atPath: url.path) { try manager.removeItem(at: url) }
  }

  func saveDownload(id: String, bytes: Data, contentType: String) throws -> URL {
    let fileExtension: String
    switch contentType {
    case "image/png": fileExtension = "png"
    case "image/jpeg": fileExtension = "jpg"
    case "image/webp": fileExtension = "webp"
    default: throw MessageCenterStorageError.invalidImage
    }
    let url = root.appendingPathComponent("downloads", isDirectory: true)
      .appendingPathComponent(id).appendingPathExtension(fileExtension)
    let temporary = root.appendingPathComponent("download-\(UUID().uuidString).tmp")
    do {
      try bytes.write(to: temporary)
      try protect(temporary)
      try FileReplacement.publish(temporary, at: url)
      return url
    } catch {
      try? manager.removeItem(at: temporary)
      throw error
    }
  }

  func cleanDownloads() throws {
    let directory = root.appendingPathComponent("downloads", isDirectory: true)
    for item in try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
      try manager.removeItem(at: item)
    }
  }

  func imageContentType(_ data: Data) -> String? {
    let bytes = [UInt8](data.prefix(12))
    if bytes.count >= 8 && Array(bytes.prefix(8)) == [137, 80, 78, 71, 13, 10, 26, 10] {
      return "image/png"
    }
    if bytes.count >= 3 && Array(bytes.prefix(3)) == [255, 216, 255] { return "image/jpeg" }
    if bytes.count >= 12 && Array(bytes.prefix(4)) == [82, 73, 70, 70]
      && Array(bytes[8..<12]) == [87, 69, 66, 80]
    {
      return "image/webp"
    }
    return nil
  }

  private func createDirectory(_ url: URL) throws {
    #if os(Windows)
      try manager.createDirectory(at: url, withIntermediateDirectories: true)
    #else
      try manager.createDirectory(
        at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    #endif
  }

  private func protect(_ url: URL) throws {
    #if !os(Windows)
      try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    #endif
  }
}

enum MessageCenterStorageError: Error, LocalizedError {
  case invalidImage
  case attachmentLimit
  case missingFeedback
  case storageUnavailable

  var errorDescription: String? {
    switch self {
    case .invalidImage: "请选择 PNG、JPEG 或 WebP 图片。"
    case .attachmentLimit: "每条反馈最多添加 3 张图片，合计不超过 10 MB。"
    case .missingFeedback: "反馈记录不可用，请刷新后重试。"
    case .storageUnavailable: "无法保存消息中心数据，请检查本机存储。"
    }
  }
}
