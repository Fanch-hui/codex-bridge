import Foundation

public protocol PiRPCTransport: Sendable {
  var incoming: AsyncThrowingStream<Data, any Error> { get }
  func send(_ record: Data) async throws
  func close() async
}

public struct PiRPCEvent: Sendable, Equatable {
  public let sequence: Int64
  public let value: PiJSONValue

  public init(sequence: Int64, value: PiJSONValue) {
    self.sequence = sequence
    self.value = value
  }
}

public struct PiRPCReply: Sendable, Equatable {
  public let data: PiJSONValue?
  public let eventSequenceBarrier: Int64

  public init(data: PiJSONValue?, eventSequenceBarrier: Int64) {
    self.data = data
    self.eventSequenceBarrier = eventSequenceBarrier
  }
}
