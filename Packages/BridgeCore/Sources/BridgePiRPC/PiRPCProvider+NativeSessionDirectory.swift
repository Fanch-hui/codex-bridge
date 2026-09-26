import BridgeAgentCore

extension PiRPCProvider: AgentNativeSessionDirectoryProviding {
  public var nativeSessionDirectoryManager: (any AgentNativeSessionDirectoryManaging)? {
    PiNativeSessionDirectoryManager(configuration: configuration)
  }
}
