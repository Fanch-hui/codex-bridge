@testable import BridgeSecurity
import Foundation
import Testing

@Suite("SecureRelativePath validation matrix")
struct SecureRelativePathTests {

  @Test("simple relative paths are accepted and normalized")
  func acceptsSimplePaths() throws {
    let path = try SecureRelativePath("Sources/Main.swift")
    #expect(path.value == "Sources/Main.swift")
    #expect(path.components == ["Sources", "Main.swift"])
  }

  @Test("nested components are preserved")
  func acceptsNestedPaths() throws {
    let path = try SecureRelativePath("a/b/c/d.txt")
    #expect(path.components == ["a", "b", "c", "d.txt"])
  }

  @Test("empty input is rejected")
  func rejectsEmpty() {
    expectError(PathSecurityError.invalidRelativePath("empty path")) {
      _ = try SecureRelativePath("")
    }
  }

  @Test("NUL bytes are rejected")
  func rejectsNUL() {
    expectError(PathSecurityError.invalidRelativePath("NUL byte")) {
      _ = try SecureRelativePath("a\0b")
    }
  }

  @Test("absolute and home-relative paths are rejected")
  func rejectsAbsolutePaths() {
    expectError(PathSecurityError.invalidRelativePath("absolute or home-relative path")) {
      _ = try SecureRelativePath("/etc/passwd")
    }
    expectError(PathSecurityError.invalidRelativePath("absolute or home-relative path")) {
      _ = try SecureRelativePath("~/secrets")
    }
  }

  @Test("file URLs are rejected")
  func rejectsFileURLs() {
    expectError(PathSecurityError.invalidRelativePath("file URL")) {
      _ = try SecureRelativePath("file:///etc/passwd")
    }
  }

  @Test("dot and parent components are rejected")
  func rejectsDotComponents() {
    for input in ["..", ".", "a/..", "../a", "a/../b", "./a", "a/."] {
      // The exact error payload is platform-specific; only the failure matters.
      let accepted = (try? SecureRelativePath(input)) != nil
      #expect(accepted == false, "expected rejection for \(input)")
    }
  }

  @Test("double separators produce empty components and are rejected")
  func rejectsEmptyComponents() {
    #expect((try? SecureRelativePath("a//b")) == nil)
    #expect((try? SecureRelativePath("a/b/")) == nil)
    #expect((try? SecureRelativePath("/")) == nil)
  }

  @Test("codable round-trip preserves the validated value")
  func codableRoundTrip() throws {
    let path = try SecureRelativePath("docs/read me.md")
    let data = try JSONEncoder().encode(path)
    let decoded = try JSONDecoder().decode(SecureRelativePath.self, from: data)
    #expect(decoded == path)
  }

  #if os(Windows)
    @Test("windows backslashes are normalized to portable separators")
    func normalizesWindowsSeparators() throws {
      let path = try SecureRelativePath("Sources\\Main.swift")
      #expect(path.value == "Sources/Main.swift")
      #expect(path.components == ["Sources", "Main.swift"])
    }

    @Test("windows control characters are rejected")
    func rejectsControlCharacters() {
      expectError(PathSecurityError.invalidRelativePath("control character")) {
        _ = try SecureRelativePath("a\tb")
      }
    }

    @Test("windows reserved device names are rejected")
    func rejectsReservedNames() {
      for input in ["CON", "con", "aux.txt", "nul.log", "COM1.bin", "LPT9", "dir/NUL"] {
        #expect((try? SecureRelativePath(input)) == nil, "expected rejection for \(input)")
      }
    }

    @Test("trailing dots and spaces are rejected")
    func rejectsTrailingDotsAndSpaces() {
      #expect((try? SecureRelativePath("file.txt.")) == nil)
      #expect((try? SecureRelativePath("file.txt ")) == nil)
    }

    @Test("drive letters and wildcards are rejected in components")
    func rejectsDrivesAndWildcards() {
      #expect((try? SecureRelativePath("C:/x")) == nil)
      #expect((try? SecureRelativePath("a/b:c")) == nil)
      #expect((try? SecureRelativePath("*.swift")) == nil)
      #expect((try? SecureRelativePath("why?.txt")) == nil)
    }
  #else
    @Test("posix keeps backslashes as ordinary characters")
    func posixKeepsBackslashes() throws {
      let path = try SecureRelativePath("a\\b")
      #expect(path.components == ["a\\b"])
      #expect(path.value == "a\\b")
    }
  #endif
}
