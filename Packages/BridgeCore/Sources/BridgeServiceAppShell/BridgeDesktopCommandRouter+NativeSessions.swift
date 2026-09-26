import BridgeDesktopUI
import BridgeMCP

extension BridgeDesktopCommandRouter {
  static func handleNativeSessionDirectory(
    _ payload: BridgeDesktopCommandPayload,
    model: BridgeServiceAppModel
  ) {
    guard connected(model), let rawOperation = validatedID(payload.action, maximumBytes: 16)
    else { return }
    if rawOperation == "close" {
      model.closeNativeSessionDirectory()
      return
    }
    guard let operation = MCPNativeSessionDirectoryOperation(rawValue: rawOperation),
      let projectID = validatedID(payload.projectID, maximumBytes: 128),
      let installationID = validatedID(payload.installationID, maximumBytes: 256)
    else { return }
    let sessionID = validatedID(payload.sessionID, maximumBytes: 256)
    if operation != .list && sessionID == nil { return }
    let request = MCPNativeSessionDirectoryRequest(
      operation: operation, projectID: projectID, installationID: installationID,
      sessionID: sessionID, offset: max(0, payload.offset ?? 0),
      limit: min(max(1, payload.limit ?? 50), 100),
      title: payload.name, confirmed: payload.confirmed ?? false)
    model.manageNativeSessionDirectory(request)
  }

  static func handleNativeSessionContinuation(
    _ envelope: BridgeDesktopCommandEnvelope,
    model: BridgeServiceAppModel
  ) {
    let payload = envelope.payload
    guard connected(model),
      let projectID = validatedID(payload.projectID, maximumBytes: 128),
      let providerID = validatedID(payload.providerID, maximumBytes: 128),
      providerID == "pi" || providerID == "qoder",
      let installationID = validatedID(payload.installationID, maximumBytes: 256),
      let sessionID = validatedID(payload.sessionID, maximumBytes: 256),
      let prompt = validatedText(payload.input, maximumBytes: 32 * 1_024)
    else { return }
    model.continueNativeAgentSession(
      projectID: projectID, providerID: providerID, installationID: installationID,
      sessionID: sessionID, prompt: prompt, requestID: envelope.requestID)
  }
}
