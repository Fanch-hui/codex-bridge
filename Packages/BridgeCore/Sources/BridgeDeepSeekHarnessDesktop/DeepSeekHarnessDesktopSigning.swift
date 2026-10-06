import BridgeACP
import BridgeAgentCore
import Crypto
import Foundation

// Key material is immutable; each signature creates its own crypto context.
struct DesktopSigning: @unchecked Sendable {
  static let protocolRevision = "codex-bridge-dsh/1"
  let privateKey: Curve25519.Signing.PrivateKey
  let publicKey: String

  init(identity: Data) throws {
    privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: identity)
    publicKey = privateKey.publicKey.rawRepresentation.base64EncodedString()
  }

  func signature(_ data: Data) throws -> String {
    try privateKey.signature(for: data).base64EncodedString()
  }

  static func verify(_ signature: String, data: Data, publicKey: String) throws {
    guard let signatureData = Data(base64Encoded: signature),
      let key = Data(base64Encoded: publicKey),
      try Curve25519.Signing.PublicKey(rawRepresentation: key)
        .isValidSignature(signatureData, for: data)
    else { throw AgentRuntimeError.unsupportedProtocol("dsh_desktop_signature") }
  }

  static func transcript(
    clientKey: String, serverKey: String, clientNonce: String, serverNonce: String,
    profileID: String, instanceID: String
  ) -> Data {
    Data(
      [
        protocolRevision, clientKey, serverKey, clientNonce, serverNonce, profileID, instanceID,
      ].joined(separator: "\n").utf8)
  }

  static func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  static func frameData(transcriptHash: String, direction: String, sequence: Int64, payload: String)
    -> Data
  {
    Data("\(transcriptHash)\n\(direction)\n\(sequence)\n\(payload)".utf8)
  }

  func frame(payload: ACPJSONValue, sequence: Int64, transcriptHash: String) throws -> ACPJSONValue
  {
    let encoded = try payload.encodedData().base64EncodedString()
    return .object([
      "type": .string("frame"), "direction": .string("client"), "sequence": .integer(sequence),
      "payload": .string(encoded),
      "signature": .string(
        try signature(
          Self.frameData(
            transcriptHash: transcriptHash, direction: "client", sequence: sequence,
            payload: encoded))),
    ])
  }

  static func payload(
    _ frame: ACPJSONValue, expectedSequence: Int64, transcriptHash: String, publicKey: String
  ) throws -> ACPJSONValue {
    guard frame["type"]?.stringValue == "frame", frame["direction"]?.stringValue == "server",
      frame["sequence"]?.intValue == Int(exactly: expectedSequence),
      let payload = frame["payload"]?.stringValue,
      let data = Data(base64Encoded: payload), data.count <= 2 * 1_024 * 1_024,
      let signature = frame["signature"]?.stringValue
    else { throw AgentRuntimeError.malformedEvent("dsh_desktop_frame") }
    try verify(
      signature,
      data: frameData(
        transcriptHash: transcriptHash, direction: "server", sequence: expectedSequence,
        payload: payload), publicKey: publicKey)
    return try JSONDecoder().decode(ACPJSONValue.self, from: data)
  }
}
