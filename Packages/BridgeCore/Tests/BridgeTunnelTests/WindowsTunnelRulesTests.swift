import XCTest

@testable import BridgeTunnel

/// The Windows helper boundary is pure byte and lexical logic, so these rules are
/// exercised on every host rather than only on Windows.
final class WindowsTunnelRulesTests: XCTestCase {
  private func pePrefix(machine: UInt16, characteristics: UInt16 = 0x0002) -> Data {
    var bytes = [UInt8](repeating: 0, count: 0x100)
    bytes[0] = 0x4D  // 'M'
    bytes[1] = 0x5A  // 'Z'
    let header = 0x80
    bytes[0x3C] = UInt8(header & 0xFF)
    bytes[0x3D] = UInt8((header >> 8) & 0xFF)
    bytes[header] = 0x50  // 'P'
    bytes[header + 1] = 0x45  // 'E'
    bytes[header + 4] = UInt8(machine & 0xFF)
    bytes[header + 5] = UInt8(machine >> 8)
    bytes[header + 22] = UInt8(characteristics & 0xFF)
    bytes[header + 23] = UInt8(characteristics >> 8)
    return Data(bytes)
  }

  func testRecognisesEverySupportedMachineFromRealHeaderLayout() {
    XCTAssertEqual(
      WindowsTunnelExecutable.architecture(ofPrefix: pePrefix(machine: 0x8664)), .amd64)
    XCTAssertEqual(
      WindowsTunnelExecutable.architecture(ofPrefix: pePrefix(machine: 0xAA64)), .arm64)
    XCTAssertEqual(
      WindowsTunnelExecutable.architecture(ofPrefix: pePrefix(machine: 0xA641)), .arm64X)
    XCTAssertEqual(
      WindowsTunnelExecutable.architecture(ofPrefix: pePrefix(machine: 0x014C)),
      .unsupported(0x014C))
  }

  func testRejectsImagesThatAreNotExecutablePE() {
    var dosOnly = [UInt8](repeating: 0, count: 0x100)
    dosOnly[0] = 0x4D
    dosOnly[1] = 0x5A
    XCTAssertEqual(
      WindowsTunnelExecutable.architecture(ofPrefix: Data(dosOnly)), .invalidHeader,
      "a text file renamed to .exe must not be accepted")

    XCTAssertEqual(
      WindowsTunnelExecutable.architecture(
        ofPrefix: pePrefix(machine: 0xAA64, characteristics: 0x0000)), .invalidHeader,
      "a PE object file without the executable characteristic is not a program")

    XCTAssertEqual(
      WindowsTunnelExecutable.architecture(ofPrefix: pePrefix(machine: 0xAA64).prefix(0x40)),
      .invalidHeader)
  }

  func testNativeArchitectureMatchesBuildArchitecture() {
    #if arch(arm64)
      XCTAssertEqual(WindowsTunnelExecutable.nativeArchitecture, .arm64)
    #elseif arch(x86_64)
      XCTAssertEqual(WindowsTunnelExecutable.nativeArchitecture, .amd64)
    #else
      XCTAssertNil(WindowsTunnelExecutable.nativeArchitecture)
    #endif
  }

  func testCrossArchitectureHelperIsRefusedButArm64XIsAcceptedOnArm64() {
    XCTAssertTrue(WindowsTunnelExecutable.matches(.arm64, native: .arm64))
    XCTAssertTrue(
      WindowsTunnelExecutable.matches(.arm64X, native: .arm64),
      "ARM64X images carry ARM64 code and must be accepted on ARM64")
    XCTAssertFalse(
      WindowsTunnelExecutable.matches(.amd64, native: .arm64),
      "an x64 helper must never be launched on ARM64")
    XCTAssertFalse(WindowsTunnelExecutable.matches(.arm64, native: .amd64))
    XCTAssertFalse(WindowsTunnelExecutable.matches(.arm64, native: nil))
    XCTAssertFalse(WindowsTunnelExecutable.matches(.invalidHeader, native: .arm64))
  }

  func testDigestPinAcceptsOnlyLowercaseHexOfExactLength() {
    XCTAssertTrue(WindowsTunnelPathRules.isValidSHA256(String(repeating: "a", count: 64)))
    XCTAssertFalse(
      WindowsTunnelPathRules.isValidSHA256(String(repeating: "A", count: 64)),
      "uppercase digests must be normalised before the pin comparison")
    XCTAssertFalse(WindowsTunnelPathRules.isValidSHA256(String(repeating: "a", count: 63)))
    XCTAssertFalse(WindowsTunnelPathRules.isValidSHA256(String(repeating: "a", count: 65)))
    XCTAssertFalse(WindowsTunnelPathRules.isValidSHA256(String(repeating: "g", count: 64)))
  }

  func testPathRulesSeparateDriveRootsFromNetworkPaths() {
    XCTAssertEqual(
      WindowsTunnelPathRules.normalize("C:/Users/me/tunnel"), "C:\\Users\\me\\tunnel")
    XCTAssertEqual(WindowsTunnelPathRules.normalize("C:\\Users\\me\\"), "C:\\Users\\me")
    XCTAssertEqual(WindowsTunnelPathRules.join("C:\\Users\\me", "run"), "C:\\Users\\me\\run")
    XCTAssertEqual(WindowsTunnelPathRules.join("C:\\Users\\me\\", "run"), "C:\\Users\\me\\run")

    XCTAssertTrue(WindowsTunnelPathRules.isLocalAbsolutePath("C:\\Users\\me"))
    XCTAssertTrue(WindowsTunnelPathRules.isLocalAbsolutePath("d:\\x"))
    XCTAssertFalse(WindowsTunnelPathRules.isLocalAbsolutePath("\\\\server\\share"))
    XCTAssertFalse(WindowsTunnelPathRules.isLocalAbsolutePath("Users\\me"))
    XCTAssertFalse(WindowsTunnelPathRules.isLocalAbsolutePath("C:x"))
    XCTAssertTrue(WindowsTunnelPathRules.isNetworkPath("\\\\server\\share"))

    let split = WindowsTunnelPathRules.components(of: "C:\\Users\\me\\run")
    XCTAssertEqual(split?.root, "C:\\")
    XCTAssertEqual(split?.tail, ["Users", "me", "run"])
    XCTAssertNil(WindowsTunnelPathRules.components(of: "\\\\server\\share"))
  }

  func testEntryNamesRejectTraversalStreamsAndDeviceNames() {
    XCTAssertTrue(WindowsTunnelPathRules.isSafeEntryName("health.url"))
    XCTAssertTrue(WindowsTunnelPathRules.isSafeEntryName("codex-home"))
    for rejected in [
      "", ".", "..", "trailing.", "trailing ", "con", "PRN", "nul", "COM1", "LPT9", "CONIN$",
      "has:colon", "has/slash", "has\\slash", "has*wildcard", "has?qmark", "has<angle>",
      "has\"quote", "has|pipe",
    ] {
      XCTAssertFalse(
        WindowsTunnelPathRules.isSafeEntryName(rejected),
        "rejected by the Windows namespace: \(rejected)")
    }
  }
}
