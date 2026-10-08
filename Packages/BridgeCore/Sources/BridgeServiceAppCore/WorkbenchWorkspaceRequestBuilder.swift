import BridgeIPC
import Foundation

public enum WorkbenchWorkspaceRequestBuilder {
  public static func request(
    action: String?, projectID: String?, selectedProjectID: String?,
    registeredProjectIDs: Set<String>, path: String? = nil, cursor: String? = nil,
    offset: Int? = nil, limit: Int? = nil, content: String? = nil,
    expectedSHA256: String? = nil, operationID: String? = nil,
    clientRequestID: String, confirmed: Bool = false
  ) throws -> IPCWorkbenchWorkspaceRequest {
    guard let projectID, projectID == selectedProjectID,
      registeredProjectIDs.contains(projectID)
    else { throw WorkbenchWorkspaceRequestError.projectChanged }
    guard let action, let operation = IPCWorkbenchWorkspaceAction(rawValue: action),
      !clientRequestID.isEmpty, clientRequestID.utf8.count <= 512
    else { throw WorkbenchWorkspaceRequestError.invalidRequest }
    return IPCWorkbenchWorkspaceRequest(
      projectID: projectID, action: operation, relativePath: path, cursor: cursor,
      startLine: offset ?? 1, lineCount: limit ?? 1_000, limit: limit ?? 100,
      content: content, expectedSHA256: expectedSHA256, operationID: operationID,
      clientRequestID: clientRequestID, confirmed: confirmed)
  }
}

private enum WorkbenchWorkspaceRequestError: LocalizedError {
  case projectChanged, invalidRequest

  var errorDescription: String? {
    switch self {
    case .projectChanged: "项目已变化，请重新选择文件。"
    case .invalidRequest: "文件操作请求不完整。"
    }
  }
}
