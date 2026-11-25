import BridgeACP

package protocol EmbeddedDSHSharedProviders: Actor {
  func call(_ action: String, payload: ACPJSONValue, timeout: Duration?) async throws
    -> ACPJSONValue
  func workbenchCall(_ input: ACPJSONValue) async throws -> ACPJSONValue
}

package protocol EmbeddedDSHProviderWorkbench: AnyObject, Sendable {
  func secret(_ input: ACPJSONValue) async throws -> ACPJSONValue
  func providerSession(_ payload: ACPJSONValue) async throws -> ACPJSONValue
  func receiveProviderEvent(_ event: EmbeddedDSHEvent) async
  func communityModelsChanged() async
}
