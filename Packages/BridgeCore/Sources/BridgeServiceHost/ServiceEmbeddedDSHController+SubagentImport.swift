import BridgeACP
import BridgeDomain
import BridgeServiceCore
import Foundation

extension ServiceEmbeddedDSHController {
  private static let maximumImportedBindings = 500

  /// `round.import`: writes the records of the earlier orchestrator's file into the ledger, in the
  /// order given. Repeating it is safe: a round that exists is left as it is (the ledger may have
  /// moved on), and a record that cannot be placed is counted instead of failing the rest.
  ///
  /// The root's project comes from the session; a child the session no longer names falls back to
  /// the project its subagent record was created in.
  func subagentRoundImport(_ payload: [String: ACPJSONValue], rootID: String) async throws
    -> ACPJSONValue
  {
    guard let items = payload["bindings"]?.arrayValue, items.count <= Self.maximumImportedBindings
    else { throw ServiceStoreError.invalidArgument("embedded_dsh.bindings") }
    let rootProject = try await storedProjectID(for: rootID)
    var tally = SubagentImportTally()
    var children = Set<String>()
    for item in items {
      let childID = item["childID"]?.stringValue
      let isFirst = childID.map { children.insert($0).inserted } ?? false
      try await importBinding(
        item.objectValue ?? [:], rootID: rootID, rootProject: rootProject, isFirst: isFirst,
        into: &tally)
    }
    if tally.imported > 0 { try await ensureSubagentScheduler(engineRunning: false).kick(rootID) }
    return tally.json
  }

  private func importBinding(
    _ binding: [String: ACPJSONValue], rootID: String, rootProject: String?, isFirst: Bool,
    into tally: inout SubagentImportTally
  ) async throws {
    do {
      guard binding["rootSessionID"]?.stringValue == rootID else {
        throw SubagentRoundImport.Skip.invalid
      }
      let projectID = try await importProject(binding, rootID: rootID, rootProject: rootProject)
      let draft = try SubagentRoundImport.draft(
        binding, rootID: rootID, projectID: projectID,
        at: .init(firstOfChild: isFirst, now: Date()))
      tally.record(try await store.insertSubagentRound(draft).created ? .imported : .existing)
    } catch let skip as SubagentRoundImport.Skip {
      tally.record(.skipped(skip))
    } catch ServiceStoreError.unknownProject {
      tally.record(.skipped(.unknownProject))
    } catch ServiceStoreError.invalidArgument("subagentRound.idempotencyConflict") {
      tally.record(.skipped(.conflict))
    } catch ServiceStoreError.invalidArgument {
      tally.record(.skipped(.invalid))
    }
  }

  private func importProject(
    _ binding: [String: ACPJSONValue], rootID: String, rootProject: String?
  ) async throws -> ProjectID {
    if let rootProject { return ProjectID(rawValue: rootProject) }
    guard let childID = binding["childID"]?.stringValue,
      let child = try await application.embeddedDSHSubagent(
        parentSessionID: rootID, childID: childID)
    else { throw SubagentRoundImport.Skip.unknownProject }
    return child.projectID
  }
}

/// What one `round.import` call did.
struct SubagentImportTally {
  enum Outcome {
    case imported, existing
    case skipped(SubagentRoundImport.Skip)
  }

  private(set) var imported = 0
  private(set) var existing = 0
  private var skipped: [SubagentRoundImport.Skip: Int] = [:]

  mutating func record(_ outcome: Outcome) {
    switch outcome {
    case .imported: imported += 1
    case .existing: existing += 1
    case .skipped(let reason): skipped[reason, default: 0] += 1
    }
  }

  var json: ACPJSONValue {
    .object([
      "imported": .integer(Int64(imported)), "existing": .integer(Int64(existing)),
      "skipped": .integer(Int64(skipped.values.reduce(0, +))),
      "reasons": .object(
        Dictionary(
          uniqueKeysWithValues: skipped.map { ($0.key.rawValue, .integer(Int64($0.value))) })),
    ])
  }
}
