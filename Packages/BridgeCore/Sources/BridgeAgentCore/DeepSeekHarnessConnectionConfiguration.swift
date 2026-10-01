import Foundation

public enum DeepSeekHarnessConnectionProtocol: String, Codable, CaseIterable, Sendable {
  case deepSeekMessages = "deepseek-messages"
  case openAICompletions = "openai-completions"
}

public struct DeepSeekHarnessConnectionConfiguration: Codable, Equatable, Sendable {
  public let inferenceProtocol: DeepSeekHarnessConnectionProtocol
  public let baseURL: String
  public let catalogBaseURL: String?

  public init(
    inferenceProtocol: DeepSeekHarnessConnectionProtocol? = nil,
    baseURL: String = "https://api.deepseek.com",
    catalogBaseURL: String? = nil
  ) {
    self.inferenceProtocol = inferenceProtocol ?? Self.inferredProtocol(baseURL: baseURL)
    self.baseURL = baseURL
    self.catalogBaseURL = catalogBaseURL
  }

  public static func inferredProtocol(baseURL: String) -> DeepSeekHarnessConnectionProtocol {
    URL(string: baseURL)?.host?.lowercased() == "api.deepseek.com"
      ? .deepSeekMessages : .openAICompletions
  }

  private enum CodingKeys: String, CodingKey {
    case inferenceProtocol = "protocol"
    case baseURL
    case catalogBaseURL
  }
}
