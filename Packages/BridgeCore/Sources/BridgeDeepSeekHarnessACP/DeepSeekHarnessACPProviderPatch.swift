import Foundation

struct DeepSeekHarnessACPProviderPatch {
  static let gatewayProviderID = "bridge-openai-gateway"

  static func make(
    modelIDs: [String], selectedModelID: String, reasoningEffort: String,
    thinkingEnabled: Bool, endpoints: DeepSeekHarnessACPEndpoints?, usesMessagesProvider: Bool
  ) -> (configuration: String, providerID: String, modelID: String) {
    let requested = DeepSeekHarnessACPModelRoutes.decode(selectedModelID)
    let model = requested?.model ?? selectedModelID
    let models = modelIDs.map { "      - id: \(yamlString($0))" }.joined(separator: "\n")
    if usesMessagesProvider, let endpoints, endpoints.inferenceProtocol == .openAICompletions {
      let entries = modelIDs.map { "            - id: \(yamlString($0))" }.joined(separator: "\n")
      return (
        """
        - id: llm-deepseek
          disabled: true
        - id: llm-deepseek-account
          disabled: true
        - id: llm-pi-ai
          config:
            providers:
              \(gatewayProviderID):
                displayName: Bridge OpenAI Gateway
                api: openai-completions
                baseURL: \(yamlString(endpoints.inferenceBaseURL))
                apiKeyEnv: DEEPSEEK_API_KEY
                models:
        \(entries)
        """, requested?.provider ?? gatewayProviderID, model
      )
    }
    let base = usesMessagesProvider ? "\n    baseURL: !!js process.env.DEEPSEEK_BASE_URL" : ""
    let apiKey = usesMessagesProvider ? "\n    apiKeyEnv: DEEPSEEK_API_KEY" : ""
    return (
      """
      - id: llm-deepseek
        config:\(base)\(apiKey)
          thinking: \(thinkingEnabled ? "enabled" : "disabled")
          reasoningEffort: \(yamlString(reasoningEffort))
          models:
      \(models)
      """, requested?.provider ?? "deepseek-official", model
    )
  }

  static func yamlString(_ value: String) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    return String(data: try! encoder.encode(value), encoding: .utf8)!
  }
}
