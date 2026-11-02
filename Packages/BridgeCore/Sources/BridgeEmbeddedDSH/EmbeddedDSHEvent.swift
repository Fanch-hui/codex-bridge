import BridgeACP
import Foundation

public struct EmbeddedDSHEvent: Equatable, Sendable {
  public let sessionID: String?
  public let type: String
  public let payload: ACPJSONValue
  public let sequence: Int64?
  public let surfaceOp: ACPJSONValue?

  public init(
    sessionID: String? = nil, type: String, payload: ACPJSONValue, sequence: Int64? = nil,
    surfaceOp: ACPJSONValue? = nil
  ) {
    self.sessionID = sessionID
    self.type = type
    self.payload = payload
    self.sequence = sequence
    self.surfaceOp = surfaceOp
  }

  init(params: ACPJSONValue) throws {
    guard let fields = params.objectValue,
      let type = fields["type"]?.stringValue, !type.isEmpty,
      type.utf8.count <= 256, !type.contains("\0"),
      let payload = fields["payload"]
    else { throw EmbeddedDSHRuntimeError.protocolViolation }
    if let value = fields["sessionID"], value != .null {
      guard let session = value.stringValue, !session.isEmpty,
        session.utf8.count <= 256, !session.contains("\0")
      else { throw EmbeddedDSHRuntimeError.protocolViolation }
      sessionID = session
    } else {
      sessionID = nil
    }
    if let value = fields["seq"], value != .null {
      guard let integer = value.intValue, integer >= 0 else {
        throw EmbeddedDSHRuntimeError.protocolViolation
      }
      sequence = Int64(integer)
    } else {
      sequence = nil
    }
    self.type = type
    self.payload = payload
    self.surfaceOp = fields["surfaceOp"]
  }
}
