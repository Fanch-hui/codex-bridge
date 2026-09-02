import XCTest

@testable import BridgeTunnel

final class WindowsTunnelRulesTests: XCTestCase {
  func testPEMachineDetection() {
    func makePE(machine: UInt16) -> Data {
      var bytes = Data(repeating: 0, count: 0x40 + 24)
      bytes[0] = 0x4D
      bytes[1] = 0x5A
      bytes[0x3C] = 0x40
      bytes[0x40] = 0x50
      bytes[0x41] = 0x45
      bytes[0x44] = UInt8(machine & 0xFF)
      bytes[0x45] = UInt8((machine >> 8) & 0xFF)
      bytes[0x40 + 22] = 0x02
      return bytes
    }
    XCTAssertEqual(
      WindowsTunnelExecutable.architecture(ofPrefix: makePE(machine: 0x8664)),
      .amd64
    )
    XCTAssertEqual(
      WindowsTunnelExecutable.architecture(ofPrefix: makePE(machine: 0xAA64)),
      .arm64
    )
    XCTAssertEqual(
      WindowsTunnelExecutable.architecture(ofPrefix: makePE(machine: 0xA641)),
      .arm64X
    )
    XCTAssertEqual(
      WindowsTunnelExecutable.architecture(ofPrefix: makePE(machine: 0x014C)),
      .unsupported(0x014C)
    )
    XCTAssertEqual(
      WindowsTunnelExecutable.architecture(ofPrefix: Data([0x4D, 0x5A])),
      .invalidHeader
    )
  }

  func testPathRules() {
    XCTAssertTrue(WindowsTunnelPathRules.isLocalAbsolutePath("C:\\Program Files\\x"))
    XCTAssertTrue(WindowsTunnelPathRules.isLocalAbsolutePath("d:\\x"))
    XCTAssertFalse(WindowsTunnelPathRules.isLocalAbsolutePath("\\\\server\\share"))
    XCTAssertFalse(WindowsTunnelPathRules.isLocalAbsolutePath("C:x"))
    XCTAssertFalse(WindowsTunnelPathRules.isLocalAbsolutePath("/etc/passwd"))
    XCTAssertTrue(WindowsTunnelPathRules.isNetworkPath("\\\\server\\share"))
    XCTAssertFalse(WindowsTunnelPathRules.isSafeEntryName("CON"))
    XCTAssertFalse(WindowsTunnelPathRules.isSafeEntryName("com1"))
    XCTAssertFalse(WindowsTunnelPathRules.isSafeEntryName("a/b"))
    XCTAssertTrue(WindowsTunnelPathRules.isSafeEntryName("r-abcdef123456"))
    XCTAssertTrue(WindowsTunnelPathRules.isValidSHA256(String(repeating: "a", count: 64)))
    XCTAssertFalse(WindowsTunnelPathRules.isValidSHA256(String(repeating: "A", count: 64)))
  }

  func testNormalizeAndJoin() {
    XCTAssertEqual(WindowsTunnelPathRules.normalize("C:/a/b/"), "C:\\a\\b")
    XCTAssertEqual(
      WindowsTunnelPathRules.join("C:\\a\\b", "c"),
      "C:\\a\\b\\c"
    )
    XCTAssertEqual(
      WindowsTunnelPathRules.join("C:\\a\\b\\", "c"),
      "C:\\a\\b\\c"
    )
  }
}
