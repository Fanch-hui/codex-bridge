import Foundation

public struct PiModelKey: Equatable, Sendable {
  public let provider: String
  public let modelID: String

  public init(provider: String, modelID: String) throws {
    guard
      [provider, modelID].allSatisfy({
        !$0.isEmpty && $0.utf8.count <= 256 && $0.rangeOfCharacter(from: .controlCharacters) == nil
      })
    else { throw PiRPCError.invalidArgument("model") }
    self.provider = provider
    self.modelID = modelID
    guard try encoded().utf8.count <= 256 else { throw PiRPCError.invalidArgument("model.length") }
  }

  public init(rawValue: String) throws {
    guard rawValue.hasPrefix("pi:"), rawValue.utf8.count <= 256 else {
      throw PiRPCError.invalidArgument("model.id")
    }
    var base64 = String(rawValue.dropFirst(3))
      .replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
    guard let bytes = Data(base64Encoded: base64),
      let values = try? JSONDecoder().decode([String].self, from: bytes), values.count == 2
    else { throw PiRPCError.invalidArgument("model.id") }
    try self.init(provider: values[0], modelID: values[1])
    guard try encoded() == rawValue else { throw PiRPCError.invalidArgument("model.id") }
  }

  public func encoded() throws -> String {
    "pi:"
      + (try JSONEncoder().encode([provider, modelID])).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }
}
