import BridgeAgentCore
import BridgeDomain
import Foundation
import Testing

@testable import BridgePiRPC

struct PiNativeSessionStoreTests {
  @Test func indexedNativeSessionCanContinueOutsideBridgeRuntimeDirectory() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("pi-\(UUID().uuidString.prefix(8))", isDirectory: true)
    let projectRoot = root.appendingPathComponent("project", isDirectory: true)
    let bridgeRoot = root.appendingPathComponent("bridge-data", isDirectory: true)
    let nativeFile = root.appendingPathComponent("pi/sessions/native.jsonl")
    try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: bridgeRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: nativeFile.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("native session".utf8).write(to: nativeFile)
    defer { try? FileManager.default.removeItem(at: root) }

    let installationID = "pi-native-test"
    let projectID = "project-native-test"
    let sessionID = "native-session-test"
    let installation = try AgentInstallation(
      id: AgentInstallationID(rawValue: installationID),
      providerID: .pi,
      executablePath: root.appendingPathComponent("pi").path)
    let request = try AgentExecutionRequest(
      taskID: TaskID(rawValue: "task-native-test"),
      projectID: ProjectID(rawValue: projectID),
      projectRoot: projectRoot.path,
      prompt: "continue native session",
      requestedSessionID: sessionID,
      mutationIntent: .readOnly,
      workspaceStrategy: .sharedProject,
      networkAccessRequested: false)
    let store = try PiSessionStore(
      baseDirectory: bridgeRoot.path, installationID: installationID, projectID: projectID)
    let binding = PiSessionBinding(
      projectID: projectID,
      projectRoot: projectRoot.path,
      installationID: installationID,
      sessionID: sessionID,
      sessionFile: nativeFile.path)

    #expect(throws: Never.self) { try store.saveNativeIndex(binding) }
    #expect(
      try store.load(sessionID: sessionID, request: request, installation: installation) == binding)
  }
}
