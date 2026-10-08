import BridgeIPC

extension BridgeServiceClientProtocol {
  public func workbenchWorkspace(_ request: IPCWorkbenchWorkspaceRequest) async throws
    -> IPCWorkbenchWorkspaceResponse
  {
    throw BridgeServiceClientError.unavailable
  }
}
