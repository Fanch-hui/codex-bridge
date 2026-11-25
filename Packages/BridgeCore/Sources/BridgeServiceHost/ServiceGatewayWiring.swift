import BridgeACP
import BridgeEmbeddedDSH
import BridgeServiceGateway
import BridgeWorkbenchService

extension ServiceEmbeddedDSHController {
  func attachCommunityGateway(_ gateway: ServiceProviderGateway) {
    closeCommunityGateway = { [weak gateway] in
      await gateway?.closeWorkbenchGateway()
    }
    workbenchGatewaySnapshot = { [weak gateway] snapshot in
      guard let gateway else { return snapshot }
      return try await gateway.workbenchSnapshot(snapshot)
    }
    workbenchGatewayEndpoint = { [weak gateway] in
      guard let gateway else { throw EmbeddedDSHRuntimeError.invalidConfiguration }
      return try await gateway.workbenchEndpoint()
    }
  }
}

extension ServiceApplicationModeController: ServiceApplicationModeControlling {}

extension ServiceEmbeddedDSHController: EmbeddedDSHProviderWorkbench {}
