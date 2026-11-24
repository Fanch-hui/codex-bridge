import BridgeServiceCore
import Foundation

extension ServiceExternalApplications {
  func codexGatewayCredential(clientID: String) async throws -> String {
    await mutationGate.acquire()
    defer { mutationGate.release() }
    guard let client = try await readClients().first(where: { $0.id == clientID }),
      client.enabled, client.platform == "codex_desktop", client.preserveOfficialLogin
    else {
      throw ServiceStoreError.invalidArgument("external_application.codex_gateway")
    }
    return try token(clientID)
  }
}
