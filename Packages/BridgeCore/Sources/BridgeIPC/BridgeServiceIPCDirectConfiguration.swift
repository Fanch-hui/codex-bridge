import Foundation

public struct IPCDirectConfiguration: Codable, Equatable, Sendable {
  public let commandMode: String
  public let allowedCommands: [String]
  public let deniedCommands: [String]
  public let usesProjectDefaults: Bool?

  public init(
    commandMode: String = "safe", allowedCommands: [String] = [], deniedCommands: [String] = [],
    usesProjectDefaults: Bool? = nil
  ) {
    self.commandMode = commandMode
    self.allowedCommands = allowedCommands
    self.deniedCommands = deniedCommands
    self.usesProjectDefaults = usesProjectDefaults
  }
}

extension BridgeServiceClient {
  public func directConfiguration() async throws -> IPCDirectConfiguration {
    try await call(operation: .getDirectConfiguration, payload: Optional<IPCMutationResponse>.none)
  }

  public func updateDirectConfiguration(_ value: IPCDirectConfiguration) async throws
    -> IPCDirectConfiguration
  {
    try await call(operation: .updateDirectConfiguration, payload: value)
  }
}
