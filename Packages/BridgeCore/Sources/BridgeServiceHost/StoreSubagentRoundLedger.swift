import BridgeServiceCore
import Foundation

/// The production ledger: the round table of the service store.
struct StoreSubagentRoundLedger: SubagentRoundLedger {
  let store: SimpleServiceStore

  func rounds(rootID: String) async throws -> [SubagentRound] {
    try await store.subagentRounds(rootID: rootID)
  }

  func insert(_ draft: SubagentRoundDraft) async throws -> SubagentRoundInsertion {
    try await store.insertSubagentRound(draft)
  }

  func update(
    _ key: SubagentRoundKey, expected: SubagentRoundPhase, to next: SubagentRoundPhase?,
    mutate: @Sendable (inout SubagentRound) throws -> Void
  ) async throws -> SubagentRoundUpdateOutcome {
    try await store.updateSubagentRound(key, expectedPhase: expected, to: next, mutate)
  }

  func markDelivered(_ key: SubagentRoundKey) async throws -> SubagentRoundUpdateOutcome {
    try await store.markSubagentRoundDelivered(key)
  }

  func openRoots() async throws -> [String] {
    try await store.rootsWithOpenSubagentRounds()
  }

  func allRoots() async throws -> [String] {
    try await store.subagentRoundRootIDs()
  }

  func roots(ofChild childID: String) async throws -> [String] {
    try await store.subagentRoundRoots(ofChild: childID)
  }

  func retire(rootID: String, now: Date, busy: Set<SubagentRoundKey>) async throws
    -> SubagentRetirement
  {
    try await store.retireSubagentRounds(
      rootID: rootID, now: now, isBusy: { busy.contains($0.key) })
  }
}
