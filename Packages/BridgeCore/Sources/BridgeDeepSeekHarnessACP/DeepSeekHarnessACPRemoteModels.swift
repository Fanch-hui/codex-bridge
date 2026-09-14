import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

struct DeepSeekHarnessACPRemoteModels {
  private struct Catalog: Decodable {
    struct Model: Decodable { let id: String }
    let data: [Model]
  }

  static func fetch(environment: [String: String]) async throws -> [String]? {
    guard let base = environment["DEEPSEEK_BASE_URL"],
      let key = environment["DEEPSEEK_API_KEY"], !key.isEmpty,
      let url = URL(string: base)?.appendingPathComponent("models")
    else { return nil }
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

public enum DeepSeekHarnessModelCatalogError: Error, LocalizedError {
  case unavailable
  case http(Int)
  case invalidResponse, empty
  public var errorDescription: String? {
    switch self {
    case .unavailable: "无法连接 DSH API 的模型目录，请检查 Base URL 与网络。"
    case .http(let status): "DSH API 模型目录返回 HTTP \(status)，请检查地址、凭据和套餐权限。"
    case .invalidResponse: "DSH API 模型目录未返回有效的 OpenAI 兼容模型列表。"
    case .empty: "DSH API 返回的模型目录为空。"
    }
  }
}
