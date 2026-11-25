import BridgeACP
import BridgeServiceCore
import Foundation

extension ServiceEmbeddedDSHController {
  static let nativeActivityEndpoints: Set<String> = [
    "job/kill", "goals/get", "goals/edit", "goals/pause", "goals/resume", "goals/clear",
    "schedule/list", "schedule/catalog", "schedule/history", "schedule/update", "schedule/delete",
  ]

  func nativeActivityRPC(
    _ endpoint: String, payload: [String: ACPJSONValue], epoch: Int
  ) async throws -> ACPJSONValue {
    let arguments = payload["payload"]?["args"]?.objectValue ?? [:]
    let sessionID: String?
    if endpoint == "schedule/catalog" {
      sessionID = nil
    } else if endpoint.hasPrefix("goals/") {
      sessionID = try Self.requiredString(arguments, "agentId")
    } else {
      guard let request = arguments["request"]?.objectValue else {
        throw ServiceStoreError.invalidArgument("embedded_dsh.client_request")
      }
      sessionID = try Self.requiredString(request, "sessionId")
    }
    if let sessionID {
      try await authorizeSession(sessionID, requiresProject: false)
      if try await storedProjectID(for: sessionID) != nil {
        let project = try await project(for: sessionID)
        let resolved = try await invokeNative(
          action: "client.workspaceSessionPath", payload: ["sessionId": .string(sessionID)],
          epoch: epoch)
        let path = try Self.requiredString(resolved.objectValue ?? [:], "path")
        guard Self.samePath(path, project.root.canonicalPath) else {
          throw ServiceStoreError.invalidArgument("embedded_dsh.session_project")
        }
      }
    }
    let result = try await invokeNative(action: "client.activity", payload: payload, epoch: epoch)
    if let sessionID { try await authorizeSession(sessionID, requiresProject: false) }
    return result
  }
}
