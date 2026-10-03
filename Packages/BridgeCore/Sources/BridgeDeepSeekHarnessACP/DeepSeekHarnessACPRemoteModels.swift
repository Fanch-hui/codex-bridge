import BridgeAgentCore
import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

struct DeepSeekHarnessACPRemoteModels {
  private struct Catalog: Decodable {
    struct Model: Decodable { let id: String }
    let data: [Model]
  }

  static func fetch(
    environment: [String: String], usesMessagesProvider: Bool = false
  ) async throws -> [String]? {
    guard let key = environment["DEEPSEEK_API_KEY"], !key.isEmpty else { return nil }
    let endpoints: DeepSeekHarnessACPEndpoints
    do {
      endpoints = try DeepSeekHarnessACPEndpoints.resolve(
        environment: environment, usesMessagesProvider: usesMessagesProvider)
    } catch {
      throw AgentModelCatalogError.invalidConfiguration
    }
    guard let url = endpoints.catalogURL else {
      throw DeepSeekHarnessModelCatalogError.catalogNotConfigured
    }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 10
    let session = URLSession(
      configuration: configuration, delegate: NoRedirect(), delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    var request = URLRequest(url: url)
    request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    let data: Data
    let response: URLResponse
    do { (data, response) = try await session.data(for: request) } catch {
      throw DeepSeekHarnessModelCatalogError.unavailable
    }
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
      throw DeepSeekHarnessModelCatalogError.http((response as? HTTPURLResponse)?.statusCode ?? 0)
    }
    return try decode(data)
  }

  static func decode(_ data: Data) throws -> [String] {
    guard data.count <= 1_048_576,
      let catalog = try? JSONDecoder().decode(Catalog.self, from: data)
    else { throw DeepSeekHarnessModelCatalogError.invalidResponse }
    var seen = Set<String>()
    let models = catalog.data.map(\.id).filter { !$0.isEmpty && seen.insert($0).inserted }
    guard !models.isEmpty else { throw DeepSeekHarnessModelCatalogError.empty }
    return models
  }

  private final class NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
      _ session: URLSession, task: URLSessionTask,
      willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
      completionHandler: @escaping (URLRequest?) -> Void
    ) { completionHandler(nil) }
  }
}

public typealias DeepSeekHarnessModelCatalogError = AgentModelCatalogError
