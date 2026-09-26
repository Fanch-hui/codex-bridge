import Foundation
import MCP

extension MCPServiceToolDispatcher {
  func callNativeSessionDirectory(
    _ name: MCPServiceToolName,
    arguments: [String: Value]?
  ) async throws -> CallTool.Result {
    let operation: MCPNativeSessionDirectoryOperation
    let allowed: Set<String>
    let required: Set<String>
    switch name {
    case .listAgentNativeSessions:
      operation = .list
      allowed = ["project_id", "installation_id", "offset", "limit"]
      required = ["project_id", "installation_id"]
    case .readAgentNativeSession:
      operation = .read
      allowed = ["project_id", "installation_id", "session_id", "offset", "limit"]
      required = ["project_id", "installation_id", "session_id"]
    case .indexAgentNativeSession:
      operation = .index
      allowed = ["project_id", "installation_id", "session_id"]
      required = allowed
    case .renameAgentNativeSession:
      operation = .rename
      allowed = ["project_id", "installation_id", "session_id", "title"]
      required = allowed
    case .deleteAgentNativeSession:
      operation = .delete
      allowed = ["project_id", "installation_id", "session_id", "confirmed"]
      required = allowed
    default:
      throw MCPError.invalidParams("Unknown native session operation.")
    }
    let values = try StrictToolArguments(arguments, allowed: allowed, required: required)
    let request = MCPNativeSessionDirectoryRequest(
      operation: operation,
      projectID: try values.requiredIdentifier("project_id", maximumUTF8Bytes: 128),
      installationID: try values.requiredIdentifier("installation_id", maximumUTF8Bytes: 256),
      sessionID: try values.optionalIdentifier("session_id", maximumUTF8Bytes: 256),
      offset: try nativeSessionOffset(values),
      limit: try values.optionalPositiveInteger("limit", maximum: 100) ?? 50,
      title: operation == .rename ? try values.requiredText("title", maximumUTF8Bytes: 4_096) : nil,
      confirmed: try values.optionalBoolean("confirmed") ?? false
    )
    let readOnly = operation == .list || operation == .read
    let deadline = clock.now.advanced(by: readOnly ? deadlines.read : deadlines.mutation)
    let response = try await withToolDeadline(until: deadline) {
      try await service.serviceNativeSessionDirectory(request, deadline: deadline)
    }
    switch operation {
    case .list:
      guard let page = response.page else { throw MCPToolAdapterError.invalidQueryOutput }
      return try resultEncoder.encode(MCPNativeSessionPageOutput(page))
    case .read:
      guard let transcript = response.transcript else {
        throw MCPToolAdapterError.invalidQueryOutput
      }
      return try resultEncoder.encode(MCPNativeSessionTranscriptOutput(transcript))
    case .index:
      guard let receipt = response.receipt else { throw MCPToolAdapterError.invalidQueryOutput }
      return try resultEncoder.encode(MCPNativeSessionIndexOutput(receipt))
    case .rename:
      guard let summary = response.summary else { throw MCPToolAdapterError.invalidQueryOutput }
      return try resultEncoder.encode(MCPNativeSessionSummaryOutput(summary))
    case .delete:
      guard response.deleted else { throw MCPToolAdapterError.invalidQueryOutput }
      return try resultEncoder.encode(MCPNativeSessionDeleteOutput())
    }
  }

  private func nativeSessionOffset(_ values: StrictToolArguments) throws -> Int {
    let offset = try values.optionalNonnegativeInteger("offset") ?? 0
    guard offset <= Int64(Int.max) else { throw MCPError.invalidParams("offset is too large.") }
    return Int(offset)
  }
}
