import Foundation
import XCTest

@testable import BridgeServiceHost

final class ServiceDataRootLockTests: XCTestCase {
  func testSameRootCannotBeOpenedUntilOwnerExits() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    var owner: ServiceDataRootLock? = try ServiceDataRootLock(rootURL: root)
    XCTAssertNotNil(owner)
    XCTAssertThrowsError(try ServiceDataRootLock(rootURL: root))
    owner = nil
    let successor = try ServiceDataRootLock(rootURL: root)
    withExtendedLifetime(successor) {}
  }
}
