import BridgeServiceAppCore
import Foundation

public struct BridgeDesktopEmbeddedDSHReceipt: Codable, Equatable, Sendable {
  public let requestID: String
  public let resultJSON: String?
  public let errorMessage: String?
  public let errorCode: String?
  public let retryable: Bool?

  public init(
    requestID: String, resultJSON: String? = nil, errorMessage: String? = nil,
    errorCode: String? = nil, retryable: Bool? = nil
  ) {
    self.requestID = requestID
    self.resultJSON = resultJSON
    self.errorMessage = errorMessage
    self.errorCode = errorCode
    self.retryable = retryable
  }

  public init(requestID: String, error: any Error) {
    let failure = BridgeServiceErrorMessage.remoteFailure(error)
    self.init(
      requestID: requestID, errorMessage: BridgeServiceErrorMessage.message(error),
      errorCode: failure?.code, retryable: failure?.retryable)
  }
}

public enum BridgeDesktopEmbeddedDSHCommand {
  public enum ValidationError: Error { case invalidRequest }

  public static func request(_ payload: BridgeDesktopCommandPayload) throws
    -> (action: String, payloadJSON: String)
  {
    guard let action = BridgeDesktopCommandValue.nonEmpty(payload.action, maximumUTF8Bytes: 128),
      action.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "_") }),
      let input = BridgeDesktopCommandValue.text(payload.input, maximumUTF8Bytes: 1_048_576),
      let data = input.data(using: .utf8),
      (try? JSONSerialization.jsonObject(with: data)) is [String: Any]
    else { throw ValidationError.invalidRequest }
    return (action: action, payloadJSON: input)
  }
}
