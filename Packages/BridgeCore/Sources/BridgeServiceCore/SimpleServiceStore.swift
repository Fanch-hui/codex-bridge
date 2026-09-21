import Dispatch
import Foundation
import GRDB

public actor SimpleServiceStore {
  private let executor: SimpleServiceStoreExecutor
  let database: DatabaseQueue
  let encoder = JSONEncoder()

  public nonisolated var unownedExecutor: UnownedSerialExecutor {
    executor.asUnownedSerialExecutor()
  }

  public init(path: String) throws {
    executor = SimpleServiceStoreExecutor()
    guard !path.isEmpty else { throw ServiceStoreError.invalidArgument("path") }
    var configuration = Configuration()
    configuration.busyMode = .timeout(5)
    configuration.foreignKeysEnabled = true
    do {
      let openedDatabase = try DatabaseQueue(path: path, configuration: configuration)
      try ServiceStoreSchema.createPreMigrationBackupIfNeeded(
        openedDatabase,
        sourcePath: path
      )
      try ServiceStoreSchema.prepare(openedDatabase)
      ServiceStoreSchema.prunePreMigrationBackups(sourcePath: path)
      database = openedDatabase
    } catch let error as ServiceStoreError {
      throw error
    } catch {
      throw ServiceStoreError.storageFailure
    }
  }

  public static func inMemory() throws -> SimpleServiceStore {
    try SimpleServiceStore(path: ":memory:")
  }
}

private final class SimpleServiceStoreExecutor: SerialExecutor {
  private let queue = DispatchQueue(label: "org.codexbridge.service-store")

  func enqueue(_ job: UnownedJob) {
    queue.async {
      job.runSynchronously(on: self.asUnownedSerialExecutor())
    }
  }

  func asUnownedSerialExecutor() -> UnownedSerialExecutor {
    UnownedSerialExecutor(ordinary: self)
  }

  func checkIsolated() {
    dispatchPrecondition(condition: .onQueue(queue))
  }
}

#if os(Linux) || os(Android) || os(Windows)
  extension SimpleServiceStoreExecutor: @unchecked Sendable {}
#endif
