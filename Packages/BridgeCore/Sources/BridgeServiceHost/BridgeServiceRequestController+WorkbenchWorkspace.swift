import BridgeIPC
import BridgeMCP
import Foundation

extension BridgeServiceRequestController {
  func handleWorkbenchWorkspace(_ request: BridgeServiceIPCRequest) async throws -> Data {
    let input = try BridgeServiceIPCCodec.payload(IPCWorkbenchWorkspaceRequest.self, from: request)
    guard !input.clientRequestID.isEmpty, input.clientRequestID.utf8.count <= 128,
      !input.clientRequestID.contains("\0")
    else { throw BridgeMCPQueryError.contractRejected }
    let app = composition.application
    let deadline = Self.deadline()
    var result = IPCWorkbenchWorkspaceResponse(projectID: input.projectID, action: input.action)
    switch input.action {
    case .listDirectory:
      result.directory = try await app.serviceWorkbenchListDirectory(
        projectID: input.projectID, relativeDirectory: input.relativePath,
        cursor: input.cursor, limit: input.limit, deadline: deadline)
    case .readFile:
      result.file = try await app.serviceWorkbenchReadFile(
        projectID: input.projectID, relativePath: requiredPath(input), startLine: input.startLine,
        lineCount: input.lineCount, deadline: deadline)
    case .gitStatus:
      let git = try await app.serviceWorkbenchGitStatus(
        projectID: input.projectID, limit: input.limit, deadline: deadline)
      result.git = IPCWorkbenchGitStatus(
        state: git.state,
        entries: git.entries.map {
          IPCWorkbenchGitEntry(
            relativePath: $0.relativePath, originalPath: $0.originalPath,
            indexStatus: $0.indexStatus, worktreeStatus: $0.worktreeStatus)
        }, truncated: git.truncated)
    case .gitDiff:
      let diff = try await app.serviceWorkbenchGitDiff(
        projectID: input.projectID, relativePath: requiredPath(input), deadline: deadline)
      result.diff = IPCWorkbenchGitDiff(
        relativePath: diff.relativePath, text: diff.text, truncated: diff.truncated)
    case .previewWrite:
      guard let content = input.content, let sha256 = input.expectedSHA256 else {
        throw BridgeMCPQueryError.contractRejected
      }
      result.preview = try await app.serviceWorkbenchPreviewWrite(
        projectID: input.projectID, relativePath: requiredPath(input), content: content,
        expectedSHA256: sha256, clientRequestID: input.clientRequestID, deadline: deadline)
    case .applyWrite:
      guard let operationID = input.operationID else { throw BridgeMCPQueryError.contractRejected }
      result.mutation = try await app.serviceWorkbenchApplyWrite(
        projectID: input.projectID, relativePath: requiredPath(input), operationID: operationID,
        clientRequestID: input.clientRequestID, confirmed: input.confirmed, deadline: deadline)
    }
    return try BridgeServiceIPCCodec.success(requestID: request.requestID, payload: result)
  }

  private func requiredPath(_ input: IPCWorkbenchWorkspaceRequest) throws -> String {
    guard let path = input.relativePath, !path.isEmpty else {
      throw BridgeMCPQueryError.contractRejected
    }
    return path
  }
}
