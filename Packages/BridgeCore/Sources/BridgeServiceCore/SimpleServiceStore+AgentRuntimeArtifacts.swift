import BridgeAgentCore
import Foundation
import GRDB

extension SimpleServiceStore {
  static func writeAgentRuntimeArtifacts(
    _ installation: ServiceAgentInstallationRecord, in db: Database
  ) throws {
    let data = try JSONEncoder().encode(installation.runtimeArtifacts)
    try db.execute(
      sql: """
        INSERT INTO bridge_service_agent_runtime_artifacts (installation_id, artifacts_json)
        VALUES (?, ?) ON CONFLICT(installation_id) DO UPDATE SET artifacts_json = excluded.artifacts_json
        """, arguments: [installation.id.rawValue, data])
  }

  static func readAgentRuntimeArtifacts(for id: AgentInstallationID, in db: Database) throws
    -> [AgentInstallationRuntimeArtifact]
  {
    guard
      let data = try Data.fetchOne(
        db,
        sql: """
          SELECT artifacts_json FROM bridge_service_agent_runtime_artifacts WHERE installation_id = ?
          """, arguments: [id.rawValue])
    else { return [] }
    return try JSONDecoder().decode([AgentInstallationRuntimeArtifact].self, from: data)
  }
}
