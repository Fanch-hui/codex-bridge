import BridgeCodexRPC
import BridgeMCP
import Foundation

enum ServiceCodexCatalogModelFetch {
  static func models(
    client: CodexAppServerClient,
    deadline: ContinuousClock.Instant
  ) async throws -> [CodexModel]? {
    var cursor: String?
    var models: [CodexModel] = []
    for _ in 0..<8 {
      guard ContinuousClock.now < deadline else { throw BridgeMCPQueryError.timeout }
      let page = try await client.listModels(
        ModelListParams(cursor: cursor, limit: 100, includeHidden: false)
      )
      // Codex can report refresh failure on stderr while returning its bundled catalog successfully.
      // That process retains the fallback; recovery requires a fresh app-server process.
      let diagnostics = String(decoding: await client.stderrSnapshot(), as: UTF8.self)
      if diagnostics.contains("failed to refresh available models:")
        || diagnostics.contains("model catalog refresh after auth change failed or timed out")
      {
        return nil
      }
      models.append(contentsOf: page.data)
      guard let next = page.nextCursor, !next.isEmpty, next != cursor else {
        guard Set(models.map(\.id)).count == models.count else {
          throw BridgeMCPQueryError.unavailable
        }
        return models
      }
      cursor = next
    }
    throw BridgeMCPQueryError.unavailable
  }
}
