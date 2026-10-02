import BridgeServiceCore
import Foundation

enum ServiceLogMaintenance {
  static func start(store: SimpleServiceStore) async -> Task<Void, Never> {
    await prune(store: store)
    return Task {
      while !Task.isCancelled {
        do {
          try await Task.sleep(for: .seconds(60 * 60))
        } catch {
          return
        }
        guard !Task.isCancelled else { return }
        await prune(store: store)
      }
    }
  }

  private static func prune(store: SimpleServiceStore) async {
    do {
      try await store.pruneTaskEventLogs()
    } catch {
      FileHandle.standardError.write(
        Data("Codex Bridge could not prune expired task logs: database storage failure.\n".utf8)
      )
    }
  }
}
