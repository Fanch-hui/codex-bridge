import BridgeDomain
import BridgeSecurity
import Foundation

struct DirectCommandSessionHistoryRecord: Codable, Sendable {
  let sessionID: String
  let projectID: String
  let argv: [String]
  let workingDirectory: String?
  let startedAt: Date
  let endedAt: Date?
  let status: String
  let exitCode: Int32?
  let timedOut: Bool
  let output: DirectCommandOutputBuffer

  init(session: DirectCommandSession) {
    sessionID = session.sessionID
    projectID = session.projectID.rawValue
    argv = OutboundContentSecurity.redactedCommandArguments(
      session.argv,
      maximumArguments: 32,
      maximumArgumentUTF8Bytes: 512
    )
    workingDirectory = session.workingDirectory.map {
      Self.summary($0, maximumUTF8Bytes: 4_096)
    }
    startedAt = session.startedAt
    endedAt = session.endedAt
    status = session.status
    exitCode = session.exitCode
    timedOut = session.timedOut
    output = DirectCommandOutputBuffer(
      head: Self.summary(session.output.head, maximumUTF8Bytes: 8 * 1_024),
      tail: Self.summary(session.output.tail, maximumUTF8Bytes: 8 * 1_024),
      byteCount: session.output.byteCount,
      truncated: session.output.truncated
    )
  }

  func session() -> DirectCommandSession? {
    guard !sessionID.isEmpty, !projectID.isEmpty, status != "running" else { return nil }
    return DirectCommandSession(
      sessionID: sessionID,
      projectID: ProjectID(rawValue: projectID),
      argv: argv,
      workingDirectory: workingDirectory,
      startedAt: startedAt,
      status: status,
      exitCode: exitCode,
      timedOut: timedOut,
      output: output,
      processID: nil,
      endedAt: endedAt
    )
  }

  private static func summary(_ value: String, maximumUTF8Bytes: Int) -> String {
    OutboundContentSecurity.redactedCommand(
      value,
      maximumUTF8Bytes: maximumUTF8Bytes
    )
  }
}

enum DirectCommandSessionHistory {
  private static let maximumFileBytes = 2 * 1_024 * 1_024

  static func load(
    from url: URL?,
    maximumCount: Int
  ) -> [DirectCommandSession] {
    guard let url, let handle = try? FileHandle(forReadingFrom: url) else { return [] }
    let data = handle.readData(ofLength: maximumFileBytes + 1)
    try? handle.close()
    guard data.count <= maximumFileBytes,
      let records = try? JSONDecoder().decode([DirectCommandSessionHistoryRecord].self, from: data)
    else { return [] }
    return records.prefix(maximumCount).compactMap { $0.session() }
  }

  static func save(
    _ sessions: some Sequence<DirectCommandSession>,
    to url: URL?,
    maximumCount: Int
  ) {
    guard let url else { return }
    var records =
      sessions
      .filter { $0.status != "running" }
      .sorted { $0.startedAt > $1.startedAt }
      .prefix(maximumCount)
      .map(DirectCommandSessionHistoryRecord.init)
    let encoder = JSONEncoder()
    var data: Data?
    repeat {
      data = try? encoder.encode(records)
      if data?.count ?? 0 <= maximumFileBytes { break }
      records.removeLast()
    } while !records.isEmpty
    guard let data, data.count <= maximumFileBytes else { return }
    try? FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try? data.write(to: url, options: .atomic)
  }
}
