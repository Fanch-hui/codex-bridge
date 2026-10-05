@testable import BridgeDirectCommand
import BridgeAgentCore
import Foundation
import Testing

@Suite("DirectPathSemantics platform path helpers")
struct DirectPathSemanticsTests {

  // MARK: basename

  @Test("basename splits on the platform separators")
  func basename() {
    #if os(Windows)
      #expect(DirectPathSemantics.basename("C:\\Tools\\git.EXE") == "git.EXE")
      #expect(DirectPathSemantics.basename("C:/mixed/path/tool.exe") == "tool.exe")
      #expect(DirectPathSemantics.basename("a\\b/c") == "c")
    #else
      #expect(DirectPathSemantics.basename("/usr/bin/git") == "git")
      #expect(DirectPathSemantics.basename("relative/file.txt") == "file.txt")
    #endif
    #expect(DirectPathSemantics.basename("solitary") == "solitary")
  }

  // MARK: hasSeparator

  @Test("separator detection follows the platform rules")
  func separatorDetection() {
    #expect(DirectPathSemantics.hasSeparator("a/b"))
    #if os(Windows)
      #expect(DirectPathSemantics.hasSeparator("a\\b"))
    #else
      #expect(!DirectPathSemantics.hasSeparator("a\\b"))
    #endif
    #expect(!DirectPathSemantics.hasSeparator("plain-name"))
  }

  // MARK: isAbsolute

  @Test("absolute detection delegates to the current style")
  func absoluteDetection() {
    #if os(Windows)
      #expect(DirectPathSemantics.isAbsolute("C:\\Program Files"))
      #expect(!DirectPathSemantics.isAbsolute("relative\\path"))
    #else
      #expect(DirectPathSemantics.isAbsolute("/usr/local"))
      #expect(!DirectPathSemantics.isAbsolute("relative/path"))
    #endif
  }

  // MARK: containedPath

  @Test("relative candidates resolve inside the project root")
  func containedRelativePath() {
    let root = TestFixtures.projectRootPath
    #expect(
      DirectPathSemantics.containedPath("Sources/Main.swift", projectRoot: root, workingDirectory: nil)
        == root + platformSeparator + "Sources" + platformSeparator + "Main.swift")
    #expect(
      DirectPathSemantics.containedPath(".", projectRoot: root, workingDirectory: nil) == root)
  }

  @Test("absolute candidates inside the root are kept")
  func containedAbsolutePath() {
    let root = TestFixtures.projectRootPath
    #if os(Windows)
      #expect(
        DirectPathSemantics.containedPath(
          "C:\\codex-bridge-tests\\proj\\notes\\a.txt",
          projectRoot: root,
          workingDirectory: nil
        ) == "C:\\codex-bridge-tests\\proj\\notes\\a.txt")
    #else
      #expect(
        DirectPathSemantics.containedPath(
          "/codex-bridge-tests/proj/notes/a.txt",
          projectRoot: root,
          workingDirectory: nil
        ) == "/codex-bridge-tests/proj/notes/a.txt")
    #endif
  }

  @Test("escapes outside the project root are rejected")
  func rejectsEscapes() {
    let root = TestFixtures.projectRootPath
    // Parent traversal.
    #expect(
      DirectPathSemantics.containedPath("../escape.txt", projectRoot: root, workingDirectory: nil)
        == nil)
    // Absolute path outside the root.
    #if os(Windows)
      #expect(
        DirectPathSemantics.containedPath("D:\\elsewhere\\x.txt", projectRoot: root, workingDirectory: nil)
          == nil)
      // Sibling directory sharing the root prefix.
      #expect(
        DirectPathSemantics.containedPath(
          "C:\\codex-bridge-tests\\proj2\\x.txt", projectRoot: root, workingDirectory: nil)
          == nil)
    #else
      #expect(
        DirectPathSemantics.containedPath("/etc/passwd", projectRoot: root, workingDirectory: nil)
          == nil)
      #expect(
        DirectPathSemantics.containedPath("/codex-bridge-tests/proj2/x.txt", projectRoot: root, workingDirectory: nil)
          == nil)
    #endif
    // Home-relative and file URLs never resolve.
    #expect(
      DirectPathSemantics.containedPath("~/x", projectRoot: root, workingDirectory: nil) == nil)
    #expect(
      DirectPathSemantics.containedPath(
        "file:///x", projectRoot: root, workingDirectory: nil) == nil)
  }

  @Test("working directories constrain the containment base")
  func containedWithWorkingDirectory() {
    let root = TestFixtures.projectRootPath
    #if os(Windows)
      let expected = "C:\\codex-bridge-tests\\proj\\sub\\a.txt"
    #else
      let expected = "/codex-bridge-tests/proj/sub/a.txt"
    #endif
    #expect(
      DirectPathSemantics.containedPath("a.txt", projectRoot: root, workingDirectory: "sub")
        == expected)
    // The working directory itself must stay inside the root.
    #expect(
      DirectPathSemantics.containedPath("a.txt", projectRoot: root, workingDirectory: "../other")
        == nil)
    #expect(
      DirectPathSemantics.containedPath("a.txt", projectRoot: root, workingDirectory: "/etc")
        == nil)
    // The `.` working directory means the project root.
    #expect(
      DirectPathSemantics.containedPath("a.txt", projectRoot: root, workingDirectory: ".")
        == root + platformSeparator + "a.txt")
  }

  private var platformSeparator: String {
    #if os(Windows)
      return "\\"
    #else
      return "/"
    #endif
  }

  // MARK: resolvedPath

  @Test("resolvedPath lexically normalizes non-existent paths")
  func resolvesNonExistentPaths() {
    #if os(Windows)
      #expect(
        DirectPathSemantics.resolvedPath("C:\\codex-bridge-tests\\proj\\a\\..\\b")
          == "C:\\codex-bridge-tests\\proj\\b")
    #else
      #expect(
        DirectPathSemantics.resolvedPath("/codex-bridge-tests/proj/a/../b")
          == "/codex-bridge-tests/proj/b")
    #endif
  }

  // MARK: isExecutableFile

  @Test("isExecutableFile reflects created files")
  func executableFileDetection() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("codex-bridge-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: directory)
    }
    #if os(Windows)
      let file = directory.appendingPathComponent("tool.exe")
    #else
      let file = directory.appendingPathComponent("tool.sh")
    #endif
    try Data("#!/bin/sh\n".utf8).write(to: file)
    #if !os(Windows)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o644], ofItemAtPath: file.path)
      #expect(!DirectPathSemantics.isExecutableFile(at: file.path))
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: file.path)
    #endif
    #expect(DirectPathSemantics.isExecutableFile(at: file.path))
    #expect(!DirectPathSemantics.isExecutableFile(at: directory.path))
  }
}
