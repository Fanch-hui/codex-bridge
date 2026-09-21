import BridgeServiceCore
import Foundation

actor ProjectGitStatusCache {
  private struct Entry {
    let path: String
    let checkedAt: ContinuousClock.Instant
    let state: String?
  }
  private var entries: [String: Entry] = [:]
  private var pending: [String: Task<String?, Never>] = [:]

  func read(_ project: ServiceProjectRecord, deadline: ContinuousClock.Instant) async -> String? {
    guard project.accessPolicy.read == .allowed else { return nil }
    let key = project.id.rawValue + "|" + project.root.canonicalPath
    if let entry = entries[key], entry.path == project.root.canonicalPath,
      entry.checkedAt.duration(to: .now) < .seconds(20)
    {
      return entry.state
    }
    if let task = pending[key] { return await task.value }
    let task = Task { await ProjectGitStatus.read(project, deadline: deadline) }
    pending[key] = task
    let state = await task.value
    pending[key] = nil
    if state != "check_failed" {
      entries[key] = Entry(path: project.root.canonicalPath, checkedAt: .now, state: state)
      entries = entries.filter { $0.value.checkedAt.duration(to: .now) < .seconds(60) }
    }
    return state
  }
}
