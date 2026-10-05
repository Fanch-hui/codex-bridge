@testable import BridgeAgentCore
import Foundation
import Testing

@Suite("AgentPathSemantics cross-platform path parsing")
struct AgentPathSemanticsTests {

  // MARK: isAbsolute

  @Test("posix absolute paths")
  func posixAbsolute() {
    #expect(AgentPathSemantics.isAbsolute("/usr/bin", style: .posix))
    #expect(AgentPathSemantics.isAbsolute("/", style: .posix))
    #expect(!AgentPathSemantics.isAbsolute("usr/bin", style: .posix))
    #expect(!AgentPathSemantics.isAbsolute("~user", style: .posix))
    #expect(!AgentPathSemantics.isAbsolute("", style: .posix))
    #expect(!AgentPathSemantics.isAbsolute("a\0b", style: .posix))
  }

  @Test("windows drive paths are absolute only with a separator after the colon")
  func windowsDriveAbsolute() {
    #expect(AgentPathSemantics.isAbsolute("C:\\Users", style: .windows))
    #expect(!AgentPathSemantics.isAbsolute("\\\\.\\C:\\Users", style: .windows))
    #expect(AgentPathSemantics.isAbsolute("C:/Users", style: .windows))
    // A drive-relative path like `C:file` has no root separator.
    #expect(!AgentPathSemantics.isAbsolute("C:file", style: .windows))
    #expect(!AgentPathSemantics.isAbsolute("file\\path", style: .windows))
  }

  @Test("UNC paths are absolute")
  func windowsUNCAbsolute() {
    #expect(AgentPathSemantics.isAbsolute("\\\\server\\share\\dir", style: .windows))
    // A single leading separator is not a UNC root.
    #expect(!AgentPathSemantics.isAbsolute("\\server", style: .windows))
  }

  @Test("NT object-manager prefixes are rejected entirely")
  func rejectsNamespacePrefixes() {
    #expect(AgentPathSemantics.canonicalPath("\\\\?\\C:\\Users", style: .windows) == nil)
    #expect(AgentPathSemantics.canonicalPath("\\\\.\\CdRom0", style: .windows) == nil)
    #expect(AgentPathSemantics.canonicalPath("\\??\\C:\\x", style: .windows) == nil)
    #expect(!AgentPathSemantics.isAbsolute("\\\\?\\C:\\Users", style: .windows))
  }

  // MARK: canonicalPath

  @Test("posix lexical normalization collapses dot segments")
  func posixCanonical() {
    #expect(AgentPathSemantics.canonicalPath("/a/b/../c", style: .posix) == "/a/c")
    #expect(AgentPathSemantics.canonicalPath("//a///b", style: .posix) == "/a/b")
    #expect(AgentPathSemantics.canonicalPath("a/b/./c", style: .posix) == "a/b/c")
    #expect(AgentPathSemantics.canonicalPath("/..", style: .posix) == "/")
    #expect(AgentPathSemantics.canonicalPath("/", style: .posix) == "/")
  }

  @Test("relative posix paths with parent escape are rejected")
  func posixParentEscapeRejected() {
    #expect(AgentPathSemantics.canonicalPath("../a", style: .posix) == nil)
    #expect(AgentPathSemantics.canonicalPath("a/../../b", style: .posix) == nil)
  }

  @Test("windows lexical normalization collapses dot segments")
  func windowsCanonical() {
    #expect(AgentPathSemantics.canonicalPath("C:\\A\\\\B\\..\\C", style: .windows) == "C:\\A\\C")
    #expect(AgentPathSemantics.canonicalPath("C:\\", style: .windows) == "C:\\")
    #expect(AgentPathSemantics.canonicalPath("C:", style: .windows) == nil)
    #expect(
      AgentPathSemantics.canonicalPath("\\\\srv\\share\\a\\..\\b", style: .windows)
        == "\\\\srv\\share\\b")
  }

  @Test("windows drive-relative paths are rejected")
  func windowsDriveRelativeRejected() {
    #expect(AgentPathSemantics.canonicalPath("C:x\\y", style: .windows) == nil)
    #expect(AgentPathSemantics.canonicalPath("a:z", style: .windows) == nil)
  }

  @Test("colons are not allowed inside windows components")
  func windowsColonRejected() {
    #expect(AgentPathSemantics.canonicalPath("C:\\a:b", style: .windows) == nil)
    #expect(AgentPathSemantics.canonicalPath("C:\\a\\b\\c:d", style: .windows) == nil)
  }

  // MARK: relativeComponents

  @Test("relative components split and reject dot segments")
  func relativeComponents() {
    #expect(AgentPathSemantics.relativeComponents("a/b/c", style: .posix) == ["a", "b", "c"])
    #expect(AgentPathSemantics.relativeComponents("a\\b\\c", style: .windows) == ["a", "b", "c"])
    #expect(AgentPathSemantics.relativeComponents("a/b/../c", style: .posix) == nil)
    #expect(AgentPathSemantics.relativeComponents("./a", style: .posix) == nil)
    #expect(AgentPathSemantics.relativeComponents("", style: .posix) == nil)
    #expect(AgentPathSemantics.relativeComponents("/a", style: .posix) == nil)
    #expect(AgentPathSemantics.relativeComponents("a//b", style: .posix) == nil)
  }

  // MARK: list handling

  @Test("path lists split per style")
  func splitsPathLists() {
    #expect(AgentPathSemantics.splitPathList("/a:/b:/c", style: .posix) == ["/a", "/b", "/c"])
    #expect(AgentPathSemantics.splitPathList("C:\\a;D:\\b", style: .windows) == ["C:\\a", "D:\\b"])
    let joined = AgentPathSemantics.joinPathList(["/a", "/b"], style: .posix)
    #expect(joined == "/a:/b")
  }

  // MARK: containment

  @Test("posix containment")
  func posixContainment() {
    #expect(AgentPathSemantics.isContained("/root/sub/file.txt", in: "/root", style: .posix))
    #expect(AgentPathSemantics.isContained("/root", in: "/root", style: .posix))
    #expect(AgentPathSemantics.isContained("/root/file.txt", in: "/root/sub", style: .posix) == false)
    // Sibling directories with a shared prefix must not leak.
    #expect(!AgentPathSemantics.isContained("/root2/file.txt", in: "/root", style: .posix))
    #expect(!AgentPathSemantics.isContained("/usr/share/x", in: "/root", style: .posix))
    // Relative candidates cannot be contained in an absolute root.
    #expect(!AgentPathSemantics.isContained("root/file.txt", in: "/root", style: .posix))
  }

  @Test("posix relativePath extraction")
  func posixRelativePath() {
    #expect(AgentPathSemantics.relativePath("/root/sub/file.txt", from: "/root", style: .posix) == "sub/file.txt")
    #expect(AgentPathSemantics.relativePath("/root/../root/a", from: "/root", style: .posix) == "a")
    #expect(AgentPathSemantics.relativePath("/etc/passwd", from: "/root", style: .posix) == nil)
  }

  @Test("windows containment is case-insensitive per component")
  func windowsContainment() {
    #expect(
      AgentPathSemantics.isContained("c:\\ROOT\\sub\\File.TXT", in: "C:\\root", style: .windows))
    #expect(
      AgentPathSemantics.isContained("C:\\root\\a\\..\\b", in: "C:\\root", style: .windows))
    #expect(
      !AgentPathSemantics.isContained("C:\\root2\\file", in: "C:\\root", style: .windows))
    #expect(
      AgentPathSemantics.isContained("\\\\srv\\share\\dir\\file", in: "\\\\SRV\\share", style: .windows))
    // Drive letters must match.
    #expect(
      !AgentPathSemantics.isContained("D:\\root\\file", in: "C:\\root", style: .windows))
  }

  @Test("posix backslashes are ordinary characters")
  func posixTreatsBackslashesAsCharacters() {
    #expect(AgentPathSemantics.canonicalPath("\\a\\b", style: .posix) == "\\a\\b")
    #expect(!AgentPathSemantics.isAbsolute("\\a\\b", style: .posix))
  }

  // MARK: directoryPath

  @Test("directory path drops the last component")
  func directoryPath() {
    #expect(AgentPathSemantics.directoryPath(of: "/a/b/c.txt", style: .posix) == "/a/b")
    #expect(AgentPathSemantics.directoryPath(of: "/a", style: .posix) == "/")
    #expect(AgentPathSemantics.directoryPath(of: "a/b", style: .posix) == "a")
    #expect(AgentPathSemantics.directoryPath(of: "C:\\a\\b.txt", style: .windows) == "C:\\a")
    #expect(AgentPathSemantics.directoryPath(of: "C:\\", style: .windows) == nil)
  }
}
