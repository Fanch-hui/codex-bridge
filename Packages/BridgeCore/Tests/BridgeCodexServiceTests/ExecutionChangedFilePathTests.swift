import BridgeDomain
import BridgeServiceCore
import Foundation
import XCTest

@testable import BridgeCodexService

final class ExecutionChangedFilePathTests: XCTestCase {
  func testWindowsChangedFileCanBePersistedAndTaskCompleted() async throws {
    let path = try ExecutionValidation.relativePath(
      #"D:\Workspace\Project\Sources\App.swift"#,
      root: "D:/Workspace/Project",
      style: .windows
    )
    XCTAssertEqual(path, "Sources/App.swift")
    let store = try SimpleServiceStore.inMemory()
    let projects = ServiceProjectService(store: store)
    let project = try await projects.register(
      name: "Changed files", rootURL: FileManager.default.temporaryDirectory)
    let tasks = ServiceTaskManager(store: store)
    let submitted = try await tasks.submit(
      ServiceTaskRequest(
        projectID: project.id, source: .chatGPT, prompt: "Update a project file",
        executionModel: "model", executionEffort: "high", permissionMode: .workspaceWrite
      )
    )
    let id = submitted.task.id
    _ = try await tasks.approveAndBegin(taskID: id)
    _ = try await tasks.markExecutionStarted(
      taskID: id, threadID: "thread-test", turnID: "turn-test")
    _ = try await tasks.recordChangedFiles(taskID: id, relativePaths: [path])
    _ = try await tasks.complete(taskID: id, resultSummary: "Done", changedFiles: [path])
    let stored = try await store.task(id: id)
    let completed = try XCTUnwrap(stored)
    XCTAssertEqual(completed.state.status, .completed)
    XCTAssertEqual(completed.state.changedFiles, ["Sources/App.swift"])
  }

  func testWindowsRelativeAndUNCPathsUsePortableSeparators() throws {
    XCTAssertEqual(
      try ExecutionValidation.relativePath(
        #"Sources\App.swift"#, root: "D:/Workspace/Project", style: .windows),
      "Sources/App.swift"
    )
    XCTAssertEqual(
      try ExecutionValidation.relativePath(
        #"\\server\share\Project\Sources\App.swift"#,
        root: #"\\server\share\Project"#, style: .windows),
      "Sources/App.swift"
    )
    XCTAssertThrowsError(
      try ExecutionValidation.relativePath(
        #"D:\Other\App.swift"#, root: "D:/Workspace/Project", style: .windows)
    )
  }
}
