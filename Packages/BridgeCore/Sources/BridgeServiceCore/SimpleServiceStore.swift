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
    if SimpleServiceStore.supportsWAL(path: path) {
      // 单连接下 WAL 的收益来自每次提交少做 fsync；操作回执与恢复依赖已提交记录在断电后仍在，
      // 因此覆盖 GRDB 在 WAL 下默认的 synchronous=NORMAL，保持 FULL。
      configuration.journalMode = .wal
    }
    do {
      let openedDatabase = try DatabaseQueue(path: path, configuration: configuration)
      try openedDatabase.inDatabase { try $0.execute(sql: "PRAGMA synchronous = FULL") }
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

  /// WAL 需要 `-wal` / `-shm` 旁路文件，网络文件系统上不可靠；内存库没有日志文件。
  /// 数据目录位于 Windows UNC 路径时沿用回滚日志模式，其余本地路径统一使用 WAL。
  private static func supportsWAL(path: String) -> Bool {
    guard path != ":memory:" else { return false }
    #if os(Windows)
      return !path.hasPrefix("\\\\") && !path.hasPrefix("//")
    #else
      return true
    #endif
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
