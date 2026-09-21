#if os(Windows)
  import BridgeDomain
  import BridgeServiceApplication
  import BridgeServiceCore
  import Foundation
  import XCTest

  final class WindowsApplicationConcurrencyTests: XCTestCase {
    func testConcurrentDirectAdmissionsLeaveOneOwnerAtMost() async throws {
      let gate = ServiceWorkspaceMutationGate()
      let projectID = ProjectID(rawValue: "prj-windows-admission")
      let store = try SimpleServiceStore.inMemory()
      let tasks = ServiceTaskManager(store: store)

      let leases = try await withThrowingTaskGroup(
        of: DirectWorkspaceLease?.self, returning: [DirectWorkspaceLease].self
      ) { group in
        for index in 0..<16 {
          group.addTask {
            do {
              return try await gate.acquireDirectLease(
                projectID: projectID,
                owner: .directFileOperation(operationID: "op-\(index)"),
                activeCodexWriteTask: {
                  try await tasks.activeWriteTask(projectID: projectID)
                }
              )
            } catch is ProjectWorkspaceBusyError {
              return nil
            }
          }
        }
        var values: [DirectWorkspaceLease] = []
        for try await lease in group {
          if let lease { values.append(lease) }
        }
        return values
      }

      XCTAssertEqual(leases.count, 1)
      for lease in leases { await lease.release() }
      let activeOwner = await gate.activeDirectOwner(projectID: projectID)
      XCTAssertNil(activeOwner)
    }

    func testConcurrentApprovalRequestsAppendOneApprovalEvent() async throws {
      let root = FileManager.default.temporaryDirectory.appending(
        path: "bridge-windows-approval-\(UUID().uuidString)",
        directoryHint: .isDirectory
      )
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
      defer { try? FileManager.default.removeItem(at: root) }

      let store = try SimpleServiceStore.inMemory()
      let projects = ServiceProjectService(store: store)
      let project = try await projects.register(
        name: "Windows approval project",
        rootURL: root,
        id: ProjectID(rawValue: "prj-windows-approval")
      )
      let tasks = ServiceTaskManager(store: store)
      let created = try await tasks.submit(
        ServiceTaskRequest(
          projectID: project.id,
          source: .chatGPT,
          prompt: "Run one approved operation.",
          executionModel: "fixture-model",
          executionEffort: "medium",
          permissionMode: .workspaceWrite
        )
      )

      let outcomes = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
        for _ in 0..<8 {
          group.addTask {
            do {
              _ = try await tasks.approveAndBegin(taskID: created.task.id)
              return true
            } catch {
              return false
            }
          }
        }
        var values: [Bool] = []
        for await value in group {
          values.append(value)
        }
        return values
      }

      XCTAssertEqual(outcomes.filter { $0 }.count, 1)
      let events = try await store.events(taskID: created.task.id)
      XCTAssertEqual(events.map(\.kind), [.taskCreated, .taskApproved])
      let stored = try await store.task(id: created.task.id)
      XCTAssertEqual(stored?.state.status, .starting)
    }
  }
#endif
