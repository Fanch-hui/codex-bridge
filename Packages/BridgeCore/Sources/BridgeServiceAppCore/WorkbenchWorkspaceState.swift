import BridgeIPC
import BridgeMCP

public struct WorkbenchWorkspaceState: Codable, Equatable, Sendable {
  public var projectID: String?
  public var selectedPath: String?
  public var directory: MCPProjectDirectoryPage?
  public var file: MCPProjectFileReadPage?
  public var git: IPCWorkbenchGitStatus?
  public var diff: IPCWorkbenchGitDiff?
  public var preview: MCPDirectMutationPreview?
  public var mutation: MCPDirectMutationReceipt?
  public var isLoading = false
  public var lastRequestID: String?
  public var errorMessage: String?
  public var errorCode: String?

  public init(projectID: String? = nil) {
    self.projectID = projectID
  }
}
