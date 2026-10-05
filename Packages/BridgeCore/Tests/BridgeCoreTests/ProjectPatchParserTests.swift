@testable import BridgeFiles
import Foundation
import Testing

@Suite("ProjectPatchParser patch syntax")
struct ProjectPatchParserTests {

  // MARK: custom (codex-style) patches

  @Test("custom update patches parse hunks and content")
  func parsesCustomUpdate() throws {
    let patch = """
      *** Begin Patch
      *** Update File: src/a.txt
      @@ context line
      -old line
      +new line
       shared line
      *** End Patch
      """
    let operations = try ProjectPatchParser.parse(patch)
    #expect(operations.count == 1)
    let operation = try #require(operations.first)
    #expect(operation.action == "update")
    #expect(operation.relativePath == "src/a.txt")
    #expect(operation.hunks.count == 1)
    let hunk = try #require(operation.hunks.first)
    #expect(hunk.context == "context line")
    #expect(hunk.removals == ["old line", "shared line"])
    #expect(hunk.additions == ["new line", "shared line"])
  }

  @Test("custom add patches must not contain removals")
  func parsesCustomAdd() throws {
    let patch = """
      *** Begin Patch
      *** Add File: new.txt
      +hello world
      *** End Patch
      """
    let operations = try ProjectPatchParser.parse(patch)
    let operation = try #require(operations.first)
    #expect(operation.action == "add")
    #expect(operation.relativePath == "new.txt")
    #expect(operation.hunks.first?.additions == ["hello world"])
    #expect(operation.hunks.first?.removals.isEmpty == true)
  }

  @Test("add patches with removals are rejected")
  func rejectsAddWithRemovals() {
    let patch = """
      *** Begin Patch
      *** Add File: new.txt
      -sneaky removal
      +hello
      *** End Patch
      """
    expectError(ProjectPatchParserError.malformedFileHeader) {
      _ = try ProjectPatchParser.parse(patch)
    }
  }

  @Test("multiple files parse in order")
  func parsesMultipleFiles() throws {
    let patch = """
      *** Begin Patch
      *** Update File: a.txt
      @@ first
      +a
      *** Update File: b.txt
      @@ second
      +b
      *** End Patch
      """
    let operations = try ProjectPatchParser.parse(patch)
    #expect(operations.map(\.relativePath) == ["a.txt", "b.txt"])
  }

  @Test("markers tolerate surrounding whitespace")
  func toleratesWhitespaceMarkers() throws {
    let patch =
      "*** Begin Patch \n"
      + "*** Update File: spaced.txt\n"
      + "@@ ctx\n"
      + "+x\n"
      + "  *** End Patch  "
    let operations = try ProjectPatchParser.parse(patch)
    #expect(operations.first?.relativePath == "spaced.txt")
    #expect(operations.first?.hunks.first?.additions == ["x"])
  }

  @Test("CRLF patches parse like LF patches")
  func parsesCRLF() throws {
    let patch = "*** Begin Patch\r\n*** Update File: a.txt\r\n@@\r\n+x\r\n*** End Patch\r\n"
    let operations = try ProjectPatchParser.parse(patch)
    #expect(operations.first?.relativePath == "a.txt")
    #expect(operations.first?.hunks.first?.additions == ["x"])
  }

  // MARK: unified (git-style) patches

  @Test("unified updates parse with normalized paths")
  func parsesUnifiedUpdate() throws {
    let patch = """
      diff --git a/src/x.txt b/src/x.txt
      index 111..222 100644
      --- a/src/x.txt\t2026-01-01
      +++ b/src/x.txt\t2026-01-02
      @@ -1 +1 @@
      -old
      +new
      \\ No newline at end of file
      """
    let operations = try ProjectPatchParser.parse(patch)
    #expect(operations.count == 1)
    let operation = try #require(operations.first)
    #expect(operation.action == "update")
    #expect(operation.relativePath == "src/x.txt")
    #expect(operation.hunks.first?.removals == ["old"])
    #expect(operation.hunks.first?.additions == ["new"])
  }

  @Test("unified new files use /dev/null")
  func parsesUnifiedAdd() throws {
    let patch = """
      --- /dev/null
      +++ b/created.txt
      @@ -0,0 +1 @@
      +content
      """
    let operations = try ProjectPatchParser.parse(patch)
    let operation = try #require(operations.first)
    #expect(operation.action == "add")
    #expect(operation.relativePath == "created.txt")
  }

  @Test("unified deletions are not supported")
  func rejectsUnifiedDelete() {
    let patch = """
      --- a/gone.txt
      +++ /dev/null
      @@ -1 +0 @@
      -content
      """
    expectError(ProjectPatchParserError.malformedFileHeader) {
      _ = try ProjectPatchParser.parse(patch)
    }
  }

  @Test("unified renames are not supported")
  func rejectsUnifiedRename() {
    let patch = """
      --- a/old.txt
      +++ b/new.txt
      @@ -1 +1 @@
      -x
      +y
      """
    expectError(ProjectPatchParserError.malformedFileHeader) {
      _ = try ProjectPatchParser.parse(patch)
    }
  }

  // MARK: rejection matrix

  @Test("missing end marker is rejected")
  func rejectsMissingEnd() {
    expectError(ProjectPatchParserError.missingEndMarker) {
      _ = try ProjectPatchParser.parse(
        """
        *** Begin Patch
        *** Update File: a.txt
        +x
        """)
    }
  }

  @Test("missing begin marker is rejected")
  func rejectsMissingBegin() {
    expectError(ProjectPatchParserError.missingBeginMarker) {
      _ = try ProjectPatchParser.parse(
        """
        *** Update File: a.txt
        +x
        *** End Patch
        """)
    }
  }

  @Test("marker-only patches are empty")
  func rejectsEmptyPatch() {
    expectError(ProjectPatchParserError.emptyPatch) {
      _ = try ProjectPatchParser.parse("*** Begin Patch\n*** End Patch")
    }
  }

  @Test("headers without hunks are rejected")
  func rejectsHunklessFile() {
    expectError(ProjectPatchParserError.emptyPatch) {
      _ = try ProjectPatchParser.parse(
        """
        *** Begin Patch
        *** Update File: a.txt
        *** End Patch
        """)
    }
  }

  @Test("absolute paths are rejected")
  func rejectsAbsolutePath() {
    expectError(ProjectPatchParserError.absolutePath) {
      _ = try ProjectPatchParser.parse(
        """
        *** Begin Patch
        *** Update File: /etc/passwd
        +x
        *** End Patch
        """)
    }
  }

  @Test("traversal paths are rejected")
  func rejectsTraversal() {
    expectError(ProjectPatchParserError.malformedFileHeader) {
      _ = try ProjectPatchParser.parse(
        """
        *** Begin Patch
        *** Update File: ../escape.txt
        +x
        *** End Patch
        """)
    }
  }

  @Test("duplicate paths are rejected")
  func rejectsDuplicatePath() {
    expectError(ProjectPatchParserError.duplicatePath) {
      _ = try ProjectPatchParser.parse(
        """
        *** Begin Patch
        *** Update File: a.txt
        +x
        *** Update File: a.txt
        +y
        *** End Patch
        """)
    }
  }

  @Test("markerless custom patches still parse")
  func parsesWithoutMarkers() throws {
    let operations = try ProjectPatchParser.parse(
      """
      *** Update File: a.txt
      +x
      """)
    #expect(operations.first?.relativePath == "a.txt")
  }
}
