import BridgeACP
import BridgeEmbeddedDSH
import BridgeModelGateway
import BridgeServiceApplication
import BridgeServiceCore
import Foundation

/// A workbench-only loopback endpoint; its credential is kept in memory.
actor ServiceWorkbenchGateway {
  private weak var gateway: ServiceProviderGateway?
  private let authentication = ServiceGatewayAuthentication()
  private let token: String
  private var listener: ModelGatewayListener?
  private var opening: Task<ModelGatewayEndpoint, any Error>?
  private var endpoint: ModelGatewayEndpoint?

  init(gateway: ServiceProviderGateway, models: [String]) throws {
    self.gateway = gateway
    token = try ServiceMCPSecretProvider.secureRandomBytes(count: 32).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
    try authentication.publish([
      ServiceExternalGatewayCredential(
        id: "bridge.workbench", token: token, generation: 0, models: models)
    ])
  }

  func updateModels(_ models: [String]) throws {
    try authentication.publish([
      ServiceExternalGatewayCredential(
        id: "bridge.workbench", token: token, generation: 0, models: models)
    ])
  }

  func start() async throws -> ACPJSONValue {
    if let endpoint { return response(endpoint) }
    let task: Task<ModelGatewayEndpoint, any Error>
    if let opening {
      task = opening
    } else {
      let auth = authentication
      let server = ModelGatewayListener(
        configuration: try ModelGatewayConfiguration(port: 0),
        authenticate: { auth.authenticate($0) },
        handler: { [weak gateway] request, sink in
          guard let gateway else { throw CancellationError() }
          try await gateway.handle(request, sink: sink, authentication: auth)
        })
      listener = server
      task = Task { try await server.start() }
      opening = task
    }
    do {
      let address = try await task.value
      endpoint = address
      opening = nil
      return response(address)
    } catch {
      opening = nil
      listener = nil
      throw error
    }
  }

  func stopAccepting() async {
    await listener?.stopAccepting()
  }

  func shutdown() async {
    await listener?.shutdown(force: true)
    listener = nil
    endpoint = nil
    opening = nil
  }

  private func response(_ endpoint: ModelGatewayEndpoint) -> ACPJSONValue {
    .object([
      "baseURL": .string("http://127.0.0.1:\(endpoint.port)/v1"),
      "token": .string(token),
    ])
  }
}

extension ServiceProviderGateway {
  package func workbenchSnapshot(_ original: ACPJSONValue) async throws -> ACPJSONValue {
    guard var fields = original.objectValue, var groups = fields["groups"]?.arrayValue else {
      throw ServiceStoreError.invalidArgument("provider.snapshot")
    }
    var routes: [String: [ServiceGatewayModel]] = [:]
    for model in models where model.pluginID != nil {
      let route = [model.pluginID!, model.providerID, model.account ?? ""]
        .map(ServiceCommunityProviders.encodedID).joined(separator: ".")
      routes["community." + route, default: []].append(model)
    }
    if !routes.isEmpty {
      let values: [ACPJSONValue] = routes.keys.sorted().map { id in
        let models = routes[id]!
        return .object([
          "id": .string(id), "name": .string(models[0].providerID),
          "models": .array(
            models.map { model in
              var value: [String: ACPJSONValue] = [
                "id": .string(model.id), "name": .string(model.name),
              ]
              if let context = model.contextWindow {
                value["contextWindow"] = .integer(Int64(context))
              }
              if let output = model.defaultMaxTokens {
                value["maxTokens"] = .integer(Int64(output))
              }
              if let images = model.supportsImages { value["images"] = .bool(images) }
              if let efforts = model.reasoningEfforts {
                value["efforts"] = .array(efforts.map(ACPJSONValue.string))
              }
              return .object(value)
            }),
        ])
      }
      groups.append(.object(["id": .string("bridge.community"), "routes": .array(values)]))
    }
    fields["groups"] = .array(groups)
    if let workbenchGateway {
      try await workbenchGateway.updateModels(models.filter { $0.pluginID != nil }.map(\.id))
    }
    return .object(fields)
  }

  package func workbenchEndpoint() async throws -> ACPJSONValue {
    let gateway: ServiceWorkbenchGateway
    if let current = workbenchGateway {
      gateway = current
    } else {
      gateway = try ServiceWorkbenchGateway(
        gateway: self, models: models.filter { $0.pluginID != nil }.map(\.id))
      workbenchGateway = gateway
    }
    return try await gateway.start()
  }

  package func closeWorkbenchGateway() async {
    guard let gateway = workbenchGateway else { return }
    await gateway.shutdown()
    if workbenchGateway === gateway { workbenchGateway = nil }
  }
}
