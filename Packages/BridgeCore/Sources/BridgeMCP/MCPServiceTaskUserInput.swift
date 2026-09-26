import Foundation

public struct MCPServiceTaskUserInputOption: Codable, Equatable, Sendable {
  public let label: String
  public let description: String

  public init(label: String, description: String) {
    self.label = label
    self.description = description
  }
}

public struct MCPServiceTaskUserInputQuestion: Codable, Equatable, Sendable {
  public let id: String
  public let header: String
  public let question: String
  public let inputType: String?
  public let allowsMultiple: Bool?
  public let allowsCustomText: Bool
  public let isSecret: Bool
  public let isRequired: Bool?
  public let options: [MCPServiceTaskUserInputOption]

  public init(
    id: String,
    header: String,
    question: String,
    inputType: String? = nil,
    allowsMultiple: Bool? = nil,
    allowsCustomText: Bool = false,
    isSecret: Bool = false,
    isRequired: Bool? = nil,
    options: [MCPServiceTaskUserInputOption] = []
  ) {
    self.id = id
    self.header = header
    self.question = question
    self.inputType = inputType
    self.allowsMultiple = allowsMultiple
    self.allowsCustomText = allowsCustomText
    self.isSecret = isSecret
    self.isRequired = isRequired
    self.options = options
  }

  private enum CodingKeys: String, CodingKey {
    case id, header, question, options
    case inputType = "input_type"
    case allowsMultiple = "allows_multiple"
    case allowsCustomText = "allows_custom_text"
    case isSecret = "is_secret"
    case isRequired = "is_required"
  }
}

public struct MCPServiceTaskUserInput: Codable, Equatable, Sendable {
  public let inputID: String
  public let title: String
  public let summary: String
  public let questions: [MCPServiceTaskUserInputQuestion]
  public let timeoutSeconds: Int?

  public init(
    inputID: String,
    title: String,
    summary: String,
    questions: [MCPServiceTaskUserInputQuestion],
    timeoutSeconds: Int? = nil
  ) {
    self.inputID = inputID
    self.title = title
    self.summary = summary
    self.questions = questions
    self.timeoutSeconds = timeoutSeconds
  }

  private enum CodingKeys: String, CodingKey {
    case inputID = "input_id"
    case title, summary, questions
    case timeoutSeconds = "timeout_seconds"
  }
}
