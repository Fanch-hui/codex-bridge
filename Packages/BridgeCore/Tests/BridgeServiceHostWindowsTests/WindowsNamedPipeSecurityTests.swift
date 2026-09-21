#if os(Windows)
  import WinSDK
  import XCTest

  @testable import BridgeServiceHost

  final class WindowsNamedPipeSecurityTests: XCTestCase {
    func testDescriptorGrantsOnlyTheCurrentUserAndSystem() {
      let userSID = "S-1-5-21-1000-2000-3000-4000"
      let descriptor = WindowsNamedPipeSecurity.sddl(for: userSID)

      XCTAssertEqual(
        descriptor,
        "D:P(A;;GA;;;S-1-5-21-1000-2000-3000-4000)(A;;GA;;;SY)"
      )
      XCTAssertFalse(descriptor.contains("WD"))
      XCTAssertFalse(descriptor.contains("AU"))
      XCTAssertFalse(descriptor.contains("BU"))
      XCTAssertFalse(descriptor.contains("BA"))
    }

    func testDescriptorCanBeMaterializedForTheCurrentProcess() throws {
      let security = try WindowsNamedPipeSecurity()
      XCTAssertNotNil(security.attributes.lpSecurityDescriptor)
    }

    func testMaterializedDescriptorRoundTripsWithoutBroadGroups() throws {
      let security = try WindowsNamedPipeSecurity()
      var rendered: LPWSTR?
      var renderedLength: ULONG = 0
      let converted = ConvertSecurityDescriptorToStringSecurityDescriptorW(
        security.attributes.lpSecurityDescriptor,
        DWORD(1),
        DWORD(DACL_SECURITY_INFORMATION),
        &rendered,
        &renderedLength
      )
      XCTAssertTrue(converted)
      guard converted, let rendered else { return }
      defer { _ = LocalFree(rendered) }

      let descriptor = String(decodingCString: rendered, as: UTF16.self)
      XCTAssertTrue(descriptor.hasPrefix("D:P"))
      XCTAssertEqual(descriptor.components(separatedBy: "(A;;GA;;;").count - 1, 2)
      XCTAssertTrue(descriptor.contains("(A;;GA;;;SY)"))
      XCTAssertFalse(descriptor.contains("(A;;GA;;;WD)"))
      XCTAssertFalse(descriptor.contains("(A;;GA;;;AU)"))
      XCTAssertFalse(descriptor.contains("(A;;GA;;;BU)"))
    }
  }
#endif
