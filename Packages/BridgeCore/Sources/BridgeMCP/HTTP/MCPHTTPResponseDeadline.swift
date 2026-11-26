import Foundation

package enum MCPHTTPResponseDeadline {
  package static func duration(body: Data, defaultDuration: Duration) -> Duration {
    guard let call = try? JSONDecoder().decode(ToolCall.self, from: body),
      call.method == "tools/call"
    else { return defaultDuration }
    if call.params?.name == MCPServiceToolName.importChatFile.rawValue {
      return max(defaultDuration, .seconds(70))
    }
    if call.params?.name == MCPServiceToolName.submitTask.rawValue,
      let arguments = call.params?.arguments
    {
      let duration = MCPServiceToolDeadlines.production.submissionDuration(
        providerID: arguments.providerID, threadID: arguments.threadID)
      return max(defaultDuration, duration + .seconds(10))
    }
    guard call.params?.name == MCPServiceToolName.waitTask.rawValue else { return defaultDuration }
    let timeout = call.params?.arguments?.timeoutSeconds ?? 300
    guard (1...300).contains(timeout) else { return defaultDuration }
    return max(defaultDuration, .seconds(timeout + 10))
  }

  private struct ToolCall: Decodable {
    let method: String
    let params: Parameters?
  }

  private struct Parameters: Decodable {
    let name: String
    let arguments: Arguments?
  }

  private struct Arguments: Decodable {
    let timeoutSeconds: Int?
    let providerID: String?
    let threadID: String?

    private enum CodingKeys: String, CodingKey {
      case timeoutSeconds = "timeout_seconds"
      case providerID = "provider_id"
      case threadID = "thread_id"
    }
  }
}
