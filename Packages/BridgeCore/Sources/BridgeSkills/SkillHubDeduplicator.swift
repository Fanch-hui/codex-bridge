import Foundation

public enum SkillHubDeduplicator {
  public static func resolve(
    occurrences: [SkillOccurrence],
    policy: SkillHubPolicy,
    projectID: String?
  ) -> [ResolvedHubSkill] {
    let grouped = Dictionary(grouping: occurrences, by: \.canonicalSlug)
    let orderMap = Dictionary(
      policy.sourceOrder.enumerated().map { ($0.element, $0.offset) },
      uniquingKeysWith: { first, _ in first }
    )

    var resolved: [ResolvedHubSkill] = []
    resolved.reserveCapacity(grouped.count)

    for (slug, rawGroup) in grouped {
      let sorted = rawGroup.sorted { lhs, rhs in
        if lhs.scope != rhs.scope {
          return lhs.scope == .project
        }
        let leftOrder = orderMap[lhs.sourceID]
        let rightOrder = orderMap[rhs.sourceID]
        switch (leftOrder, rightOrder) {
        case (let l?, let r?) where l != r:
          return l < r
        case (_?, nil) where lhs.scope == .global:
          return true
        case (nil, _?) where rhs.scope == .global:
          return false
        default:
          break
        }
        if lhs.priorityRank != rhs.priorityRank {
          return lhs.priorityRank < rhs.priorityRank
        }
        return lhs.entryPath.localizedCaseInsensitiveCompare(rhs.entryPath) == .orderedAscending
      }
      guard let defaultWinner = sorted.first else { continue }

      let itemPolicy = policy.skillPolicies[slug]
      let pinnedID = itemPolicy?.pinnedOccurrenceID
      let pinnedMatch = pinnedID.flatMap { id in sorted.first(where: { $0.id == id }) }
      let winner = pinnedMatch ?? defaultWinner
      let activePinnedID = pinnedMatch?.id

      var variants: [SkillVariantView] = []
      variants.reserveCapacity(sorted.count)
      var mergedSources: [String] = []
      var seenSourceNames = Set<String>()
      var sameTierBundleHashes = Set<String>()
      var hasProjectOverride = false

      for item in sorted {
        let relation: SkillDedupRelation
        if item.id == winner.id {
          relation = .winner
        } else if item.physicalKey == winner.physicalKey {
          relation = .samePhysical
        } else if item.bundleHash == winner.bundleHash {
          relation = .sameContent
        } else if winner.scope == .project, item.scope == .global {
          relation = .overriddenByProject
          hasProjectOverride = true
        } else {
          relation = .conflict
        }
        variants.append(
          SkillVariantView(
            occurrence: item,
            relation: relation,
            isPinned: activePinnedID == item.id
          )
        )
        if relation == .winner || relation == .samePhysical || relation == .sameContent {
          if seenSourceNames.insert(item.sourceName).inserted {
            mergedSources.append(item.sourceName)
          }
        }
        if relation == .winner || relation == .conflict {
          sameTierBundleHashes.insert(item.bundleHash)
        }
      }

      let conflictHashes = max(0, sameTierBundleHashes.count)
      let hasConflict = conflictHashes > 1
      let projectOverride = projectID.flatMap { policy.projectSkillOverrides[$0]?[slug] }
      let invocationMode = projectOverride ?? itemPolicy?.invocationMode ?? .autoAndManual

      let effectiveModelInvocable: Bool
      let effectiveUserInvocable: Bool
      switch invocationMode {
      case .autoAndManual:
        effectiveModelInvocable = winner.frontmatterModelInvocable
        effectiveUserInvocable = winner.frontmatterUserInvocable
      case .manualOnly:
        effectiveModelInvocable = false
        effectiveUserInvocable = winner.frontmatterUserInvocable
      case .disabled:
        effectiveModelInvocable = false
        effectiveUserInvocable = false
      }

      let manifest = SkillManifest(
        name: slug,
        description: winner.description,
        scope: winner.scope,
        rootPath: winner.canonicalRootPath,
        triggers: winner.triggers,
        actions: winner.actions,
        hasReferences: winner.hasReferences
      )

      resolved.append(
        ResolvedHubSkill(
          canonicalSlug: slug,
          displayName: winner.rawName,
          description: winner.description,
          whenToUse: winner.whenToUse,
          scope: winner.scope,
          winner: winner,
          variants: variants,
          mergedSourceNames: mergedSources,
          hasConflict: hasConflict,
          conflictCount: hasConflict ? conflictHashes : 0,
          hasProjectOverride: hasProjectOverride,
          invocationMode: invocationMode,
          effectiveModelInvocable: effectiveModelInvocable,
          effectiveUserInvocable: effectiveUserInvocable,
          pinnedOccurrenceID: activePinnedID,
          projectOverrideMode: projectOverride,
          manifest: manifest
        )
      )
    }

    return resolved.sorted {
      $0.canonicalSlug.localizedCaseInsensitiveCompare($1.canonicalSlug) == .orderedAscending
    }
  }
}
