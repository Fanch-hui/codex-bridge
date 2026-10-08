import Foundation

public struct DSHConversationExecutionSelection: Codable, Equatable, Sendable {
  public let modelID: String?
  public let effort: String?
  public let permissionMode: String

  public init(modelID: String?, effort: String?, permissionMode: String) {
    self.modelID = modelID
    self.effort = effort
    self.permissionMode = permissionMode
  }

  public func validated() throws -> Self {
    guard permissionMode == "full" else {
      throw DSHWorkbenchTaskSubmission.SubmissionError.permissionUnsupported
    }
    return try Self(
      modelID: selection(modelID, maximumBytes: 256),
      effort: selection(effort, maximumBytes: 64), permissionMode: permissionMode)
  }

  private func selection(_ value: String?, maximumBytes: Int) throws -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.utf8.count <= maximumBytes,
      trimmed.rangeOfCharacter(from: .controlCharacters) == nil
    else { throw DSHWorkbenchTaskSubmission.SubmissionError.invalidInput }
    return trimmed.isEmpty || trimmed == "provider-default" ? nil : trimmed
  }
}
