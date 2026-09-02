import Crypto
import Foundation
import XCTest

@testable import BridgeTunnel

final class WindowsTunnelHelperVerifierTests: XCTestCase {
  private var temporaryDirectory: URL!

  override func setUpWithError() throws {
    temporaryDirectory = FileManager.default.temporaryDirectory.appending(
      path: "codexbridge-tunnel-verify-\(UUID().uuidString.lowercased())",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(
      at: temporaryDirectory,
      withIntermediateDirectories: true
    )
  }

  override func tearDownWithError() throws {
    if let temporaryDirectory {
      try? FileManager.default.removeItem(at: temporaryDirectory)
    }
  }

  private static func systemExecutable() throws -> URL {
    let systemRoot = ProcessInfo.processInfo.environment["SystemRoot"] ?? "C:\\Windows"
    return URL(fileURLWithPath: systemRoot).appendingPathComponent("System32\\cmd.exe")
  }

  private static func digestHex(of data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  func testVerifiesRealSystemExecutable() throws {
    let executable = try Self.systemExecutable()
    let data = try Data(contentsOf: executable)
    let helper = try TunnelHelperVerifier().verify(
      executable: executable,
      expectedSHA256: Self.digestHex(of: data)
    )
    XCTAssertEqual(helper.executable, executable)
  }

  func testRejectsDigestMismatch() throws {
    let executable = try Self.systemExecutable()
    XCTAssertThrowsError(
      try TunnelHelperVerifier().verify(
        executable: executable,
        expectedSHA256: String(repeating: "0", count: 64)
      )
    ) { error in
      XCTAssertEqual(error as? TunnelHelperError, .digestMismatch)
    }
  }

  func testRejectsDirectoryAsExecutable() throws {
    XCTAssertThrowsError(
      try TunnelHelperVerifier().verify(
        executable: temporaryDirectory,
        expectedSHA256: String(repeating: "0", count: 64)
      )
    ) { error in
      XCTAssertEqual(error as? TunnelHelperError, .notRegularFile)
    }
  }

  func testRejectsNonExecutableImage() throws {
    let textFile = temporaryDirectory.appendingPathComponent("not-an-exe.txt")
    let data = Data("plain text".utf8)
    try data.write(to: textFile)
    XCTAssertThrowsError(
      try TunnelHelperVerifier().verify(
        executable: textFile,
        expectedSHA256: Self.digestHex(of: data)
      )
    ) { error in
      XCTAssertEqual(error as? TunnelHelperError, .notExecutable)
    }
  }

  func testRejectsMissingExecutable() throws {
    XCTAssertThrowsError(
      try TunnelHelperVerifier().verify(
        executable: temporaryDirectory.appendingPathComponent("missing.exe"),
        expectedSHA256: String(repeating: "0", count: 64)
      )
    ) { error in
      XCTAssertEqual(error as? TunnelHelperError, .unavailable)
    }
  }
}
