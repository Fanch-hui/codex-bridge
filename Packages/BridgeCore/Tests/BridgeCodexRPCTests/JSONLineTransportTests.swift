@preconcurrency import Foundation
import XCTest

@testable import BridgeCodexRPC

final class JSONLineTransportTests: XCTestCase {
  func testShortResponseArrivesWhileOutputPipeRemainsOpen() async throws {
    let input = Pipe()
    let output = Pipe()
    let writer = output.fileHandleForWriting
    let dispatcher = RPCDispatcher()
    let transport = JSONLineTransport(
      input: input.fileHandleForWriting,
      output: output.fileHandleForReading,
      dispatcher: dispatcher,
      maximumLineBytes: 1_024
    )
    try await transport.start(onProtocolFailure: {})
    do {
      let result = try await dispatcher.request(
        id: .integer(1), method: "model/list", timeoutNanoseconds: 2_000_000_000
      ) {
        try writer.write(contentsOf: Data("{\"id\":1,\"result\":{\"data\":[]}}\n".utf8))
      }
      XCTAssertEqual(result, .object(["data": .array([])]))
    } catch {
      try? writer.close()
      await transport.stop()
      throw error
    }
    try writer.close()
    await transport.stop()
    try input.fileHandleForReading.close()
  }
}
