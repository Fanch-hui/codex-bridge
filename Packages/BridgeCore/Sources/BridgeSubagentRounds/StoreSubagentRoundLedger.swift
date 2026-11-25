import BridgeServiceCore
import Foundation

/// The production ledger: the round table of the service store.
package struct StoreSubagentRoundLedger: SubagentRoundLedger {
  let store: SimpleServiceStore

  package init(store: SimpleServiceStore) { self.store = store }

  package func rounds(rootID: String) async throws -> [SubagentRound] {
    try await store.subagentRounds(rootID: rootID)
  }

  package func insert(_ draft: SubagentRoundDraft) async throws -> SubagentRoundInsertion {
    try await store.insertSubagentRound(draft)
  }

  package func update(
    _ key: SubagentRoundKey, expected: SubagentRoundPhase, to next: SubagentRoundPhase?,
    mutate: @Sendable (inout SubagentRound) throws -> Void
  ) async throws -> SubagentRoundUpdateOutcome {
    try await store.updateSubagentRound(key, expectedPhase: expected, to: next, mutate)
  }

  package func markDelivered(_ key: SubagentRoundKey) async throws -> SubagentRoundUpdateOutcome {
    try await store.markSubagentRoundDelivered(key)
  }

  package func openRoots() async throws -> [String] {
    try await store.rootsWithOpenSubagentRounds()
  }

  package func allRoots() async throws -> [String] {
    try await store.subagentRoundRootIDs()
  }

  package func roots(ofChild childID: String) async throws -> [String] {
    try await store.subagentRoundRoots(ofChild: childID)
  }

  package func retire(rootID: String, now: Date, busy: Set<SubagentRoundKey>) async throws
    -> SubagentRetirement
  {
    try await store.retireSubagentRounds(
      rootID: rootID, now: now, isBusy: { busy.contains($0.key) })
  }
}
