@testable import BridgeGit
import Foundation
import Testing

@Suite("GitStatusParser porcelain v2 -z")
struct GitStatusParserTests {

  private let parser = GitStatusParser(
    maximumFileCount: 10_000,
    maximumPathBytes: 4_096,
    maximumAggregatePathBytes: 2 * 1_024 * 1_024
  )

  @Test("empty input parses to a clean working tree")
  func parsesEmptyInput() throws {
    let evidence = try parser.parse(Data())
    #expect(evidence.repositoryClassification == .gitWorkingTree)
    #expect(evidence.branch == nil)
    #expect(evidence.headCommit == nil)
    #expect(evidence.detachedHead == false)
    #expect(evidence.entries.isEmpty)
    #expect(evidence.isDirty == false)
  }

  @Test("leading and trailing NUL bytes are ignored")
  func skipsEmptyTokens() throws {
    let data = TestFixtures.porcelain(["", "# branch.head main", ""])
    let evidence = try parser.parse(data)
    #expect(evidence.branch == "main")
    #expect(evidence.entries.isEmpty)
  }

  @Test("branch headers set branch, head commit and detached state")
  func parsesHeaders() throws {
    let evidence = try parser.parse(
      TestFixtures.porcelain([
        "# branch.oid 1234567890abcdef1234567890abcdef12345678",
        "# branch.head feature/chat",
      ]))
    #expect(evidence.branch == "feature/chat")
    #expect(evidence.headCommit == "1234567890abcdef1234567890abcdef12345678")
    #expect(evidence.detachedHead == false)
  }

  @Test("initial repository has no head commit")
  func parsesInitialRepository() throws {
    let evidence = try parser.parse(
      TestFixtures.porcelain(["# branch.oid (initial)", "# branch.head main"]))
    #expect(evidence.headCommit == nil)
    #expect(evidence.branch == "main")
  }

  @Test("detached HEAD keeps no branch name")
  func parsesDetachedHead() throws {
    let evidence = try parser.parse(
      TestFixtures.porcelain([
        "# branch.oid 1234567890abcdef1234567890abcdef12345678",
        "# branch.head (detached)",
      ]))
    #expect(evidence.branch == nil)
    #expect(evidence.detachedHead == true)
    #expect(evidence.headCommit == "1234567890abcdef1234567890abcdef12345678")
  }

  @Test("unrelated headers are ignored")
  func ignoresUnrelatedHeaders() throws {
    let evidence = try parser.parse(
      TestFixtures.porcelain([
        "# branch.upstream origin/feature/chat",
        "# stash 2",
        "# branch.oid 1234567890abcdef1234567890abcdef12345678",
        "# branch.head main",
      ]))
    #expect(evidence.branch == "main")
    #expect(evidence.headCommit == "1234567890abcdef1234567890abcdef12345678")
  }

  @Test("ordinary entries expose index and worktree statuses")
  func parsesOrdinaryEntry() throws {
    let evidence = try parser.parse(
      TestFixtures.porcelain([
        "1 .M N... 100644 100644 100644 1111111111111111111111111111111111111111 2222222222222222222222222222222222222222 Sources/Main.swift",
      ]))
    #expect(evidence.entries.count == 1)
    let entry = try #require(evidence.entries.first)
    #expect(entry.kind == .ordinary)
    #expect(entry.path == "Sources/Main.swift")
    #expect(entry.indexStatus == ".")
    #expect(entry.workTreeStatus == "M")
    #expect(entry.originalPath == nil)
    #expect(evidence.isDirty == true)
  }

  @Test("ordinary entries keep paths containing spaces intact")
  func parsesPathsWithSpaces() throws {
    let evidence = try parser.parse(
      TestFixtures.porcelain([
        "1 .M N... 100644 100644 100644 1111111111111111111111111111111111111111 2222222222222222222222222222222222222222 file with spaces.txt",
      ]))
    #expect(evidence.entries.first?.path == "file with spaces.txt")
  }

  @Test("untracked entries carry no statuses")
  func parsesUntrackedEntry() throws {
    let evidence = try parser.parse(
      TestFixtures.porcelain(["? Notes/new-idea.md"]))
    let entry = try #require(evidence.entries.first)
    #expect(entry.kind == .untracked)
    #expect(entry.path == "Notes/new-idea.md")
    #expect(entry.indexStatus == nil)
    #expect(entry.workTreeStatus == nil)
  }

  @Test("renamed entries consume the next NUL token as the original path")
  func parsesRenamedEntry() throws {
    let evidence = try parser.parse(
      TestFixtures.porcelain([
        "2 R. N... 100644 100644 100644 1111111111111111111111111111111111111111 2222222222222222222222222222222222222222 R100 Sources/NewName.swift",
        "Sources/OldName.swift",
        "? Untracked.swift",
      ]))
    #expect(evidence.entries.count == 2)
    let renamed = try #require(evidence.entries.first)
    #expect(renamed.kind == .renamedOrCopied)
    #expect(renamed.path == "Sources/NewName.swift")
    #expect(renamed.originalPath == "Sources/OldName.swift")
    #expect(renamed.indexStatus == "R")
    #expect(renamed.workTreeStatus == ".")
    #expect(evidence.entries.last?.kind == .untracked)
  }

  @Test("unmerged entries parse after ten header fields")
  func parsesUnmergedEntry() throws {
    let evidence = try parser.parse(
      TestFixtures.porcelain([
        "u AA N... 000000 100644 100644 000000 000000 100644 1111111111111111111111111111111111111111 2222222222222222222222222222222222222222 conflicted.txt",
      ]))
    let entry = try #require(evidence.entries.first)
    #expect(entry.kind == .unmerged)
    #expect(entry.path == "conflicted.txt")
    #expect(entry.indexStatus == "A")
    #expect(entry.workTreeStatus == "A")
  }

  @Test("invalid UTF-8 paths decode lossily instead of throwing")
  func decodesLossyUTF8() throws {
    var record = Array("? c".utf8)
    record.append(0xFF)
    record.append(contentsOf: Array("d.txt".utf8))
    record.append(0)
    let evidence = try parser.parse(Data(record))
    #expect(evidence.entries.first?.path == "c\u{FFFD}d.txt")
  }

  @Test("unknown record markers are rejected")
  func rejectsUnknownMarker() {
    expectError(GitEvidenceError.malformedGitOutput) {
      _ = try parser.parse(TestFixtures.porcelain(["x some junk"]))
    }
  }

  @Test("renamed entries without an original-path token are rejected")
  func rejectsTruncatedRename() {
    expectError(GitEvidenceError.malformedGitOutput) {
      _ = try parser.parse(
        TestFixtures.porcelain([
          "2 R. N... 100644 100644 100644 1111 2222 R100 NewName.swift",
        ]))
    }
  }

  @Test("short ordinary entries are rejected")
  func rejectsShortOrdinaryEntry() {
    expectError(GitEvidenceError.malformedGitOutput) {
      _ = try parser.parse(TestFixtures.porcelain(["1 .M"]))
    }
  }

  @Test("short untracked entries are rejected")
  func rejectsShortUntrackedEntry() {
    expectError(GitEvidenceError.malformedGitOutput) {
      _ = try parser.parse(TestFixtures.porcelain(["? "]))
    }
  }

  @Test("file count limit is enforced")
  func enforcesFileCountLimit() {
    let strict = GitStatusParser(
      maximumFileCount: 1,
      maximumPathBytes: 4_096,
      maximumAggregatePathBytes: 2 * 1_024 * 1_024
    )
    expectError(GitEvidenceError.fileCountLimitExceeded) {
      _ = try strict.parse(
        TestFixtures.porcelain(["? a.txt", "? b.txt"]))
    }
  }

  @Test("per-path byte limit is enforced")
  func enforcesPathByteLimit() {
    let strict = GitStatusParser(
      maximumFileCount: 10,
      maximumPathBytes: 4,
      maximumAggregatePathBytes: 2 * 1_024 * 1_024
    )
    expectError(GitEvidenceError.pathByteLimitExceeded) {
      _ = try strict.parse(TestFixtures.porcelain(["? a-long-filename.txt"]))
    }
  }

  @Test("aggregate path byte limit is enforced")
  func enforcesAggregateLimit() {
    let strict = GitStatusParser(
      maximumFileCount: 10,
      maximumPathBytes: 4_096,
      maximumAggregatePathBytes: 10
    )
    expectError(GitEvidenceError.aggregatePathByteLimitExceeded) {
      _ = try strict.parse(TestFixtures.porcelain(["? 012345", "? 012345"]))
    }
  }

  @Test("porcelain bytes round-trip through the evidence")
  func retainsRawPorcelain() throws {
    let data = TestFixtures.porcelain(["# branch.head main", "? a.txt"])
    let evidence = try parser.parse(data)
    #expect(evidence.porcelainV2 == data)
  }
}
