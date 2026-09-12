#if os(Windows)
  import Foundation
  import XCTest

  @testable import BridgeCodexRPC

  final class CodexWindowsPackagedRuntimeTests: XCTestCase {
    func testCopiesPackagedCLIAndAvailableCompanionsIntoCache() throws {
      let fixture = try Fixture()
      defer { fixture.remove() }

      let resources = fixture.path("package", "app", "resources")
      let executable = resources.appendingPathComponent("codex.exe")
      let runner = resources.appendingPathComponent("codex-command-runner.exe")
      let notices = resources.appendingPathComponent("THIRD_PARTY_NOTICES.txt")
      try fixture.write(Self.peImage(), to: executable)
      try fixture.write(Self.peImage(), to: runner)
      try fixture.write(Data("third-party notices\n".utf8), to: notices)
      try fixture.write(
        Data("GUI resources\n".utf8),
        to: fixture.path("package", "app", "app.asar")
      )

      let target = fixture.path("cache", "OpenAI.Codex_test")
      let result = try CodexWindowsPackagedRuntime.executableCopyIfPackaged(
        at: executable,
        resourcesDirectory: resources,
        targetDirectory: target
      )

      XCTAssertEqual(
        CodexWindowsPath.normalize(result?.path ?? ""),
        CodexWindowsPath.normalize(target.appendingPathComponent("codex.exe").path)
      )
      XCTAssertEqual(
        try Data(contentsOf: target.appendingPathComponent("codex.exe")),
        try Data(contentsOf: executable)
      )
      XCTAssertEqual(
        try Data(contentsOf: target.appendingPathComponent(runner.lastPathComponent)),
        try Data(contentsOf: runner)
      )
      XCTAssertEqual(
        try Data(contentsOf: target.appendingPathComponent(notices.lastPathComponent)),
        try Data(contentsOf: notices)
      )
      XCTAssertFalse(
        FileManager.default.fileExists(atPath: target.appendingPathComponent("app.asar").path))
    }

    func testReusesMatchingPackagedRuntimeCache() throws {
      let fixture = try Fixture()
      defer { fixture.remove() }

      let resources = fixture.path("package", "app", "resources")
      let executable = resources.appendingPathComponent("codex.exe")
      try fixture.write(Self.peImage(), to: executable)
      let target = fixture.path("cache", "OpenAI.Codex_test")

      let first = try CodexWindowsPackagedRuntime.executableCopyIfPackaged(
        at: executable,
        resourcesDirectory: resources,
        targetDirectory: target
      )
      let cachedData = try Data(contentsOf: target.appendingPathComponent("codex.exe"))
      let second = try CodexWindowsPackagedRuntime.executableCopyIfPackaged(
        at: executable,
        resourcesDirectory: resources,
        targetDirectory: target
      )

      XCTAssertEqual(
        CodexWindowsPath.normalize(first?.path ?? ""),
        CodexWindowsPath.normalize(second?.path ?? ""))
      XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("codex.exe")), cachedData)
    }

    private static func peImage() -> Data {
      let machine: UInt16 = CodexWindowsArchitecture.current == .arm64 ? 0xAA64 : 0x8664
      var bytes = [UInt8](repeating: 0, count: 512)
      bytes[0] = 0x4D
      bytes[1] = 0x5A
      bytes[0x3C] = 0x80
      bytes[0x80] = 0x50
      bytes[0x81] = 0x45
      bytes[0x84] = UInt8(machine & 0xFF)
      bytes[0x85] = UInt8(machine >> 8)
      bytes[0x96] = 0x02
      return Data(bytes)
    }
  }

  private final class Fixture {
    let root: URL

    init() throws {
      root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "codex-packaged-runtime-\(UUID().uuidString)",
        isDirectory: true
      )
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func path(_ components: String...) -> URL {
      components.reduce(root) { url, component in
        url.appendingPathComponent(component, isDirectory: !component.contains("."))
      }
    }

    func write(_ data: Data, to path: URL) throws {
      try FileManager.default.createDirectory(
        at: path.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try data.write(to: path)
    }

    func remove() {
      try? FileManager.default.removeItem(at: root)
    }
  }
#endif
