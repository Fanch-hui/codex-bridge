import BridgeIPC
import Foundation
import XCTest

@testable import BridgeServiceHost

final class DirectConfigurationHostTests: XCTestCase {
  func testGlobalDirectConfigurationRoundTripsThroughRequestController() async throws {
    let fixture = try await makeServiceHostFixture(self)
    let controller = BridgeServiceRequestController(composition: fixture.composition)
    let input = IPCDirectConfiguration(allowedCommands: ["npm test"], deniedCommands: ["git push"])
    let update = try BridgeServiceIPCCodec.request(
      operation: .updateDirectConfiguration, payload: input, requestID: "update")
    let response = await controller.dispatch(update)
    let saved = try BridgeServiceIPCCodec.decodeResponse(
      IPCDirectConfiguration.self, data: response, requestID: "update")
    XCTAssertEqual(saved.allowedCommands, input.allowedCommands)
    XCTAssertEqual(saved.usesProjectDefaults, false)
    let get = try BridgeServiceIPCCodec.request(
      operation: .getDirectConfiguration, payload: IPCMutationResponse(), requestID: "get")
    let loadedData = await controller.dispatch(get)
    let loaded = try BridgeServiceIPCCodec.decodeResponse(
      IPCDirectConfiguration.self, data: loadedData, requestID: "get")
    XCTAssertEqual(loaded, saved)
  }
}
