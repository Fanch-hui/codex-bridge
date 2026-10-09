import BridgeCodexRPC
import BridgeMCP
import BridgeSecurity
import Foundation

enum ServiceCodexCatalogModelFetch {
  enum Outcome: Sendable {
    case models([CodexModel])
    case refreshFailed(String)
  }

  static func models(
    client: CodexAppServerClient,
    deadline: ContinuousClock.Instant
  ) async throws -> Outcome {
    var cursor: String?
    var models: [CodexModel] = []
    for _ in 0..<8 {
      guard ContinuousClock.now < deadline else { throw BridgeMCPQueryError.timeout }
      let page: ModelListResponse
      do {
        page = try await client.listModels(
          ModelListParams(cursor: cursor, limit: 100, includeHidden: false)
        )
      } catch let error as DecodingError {
        throw ServiceCodexModelCatalogDiagnostics.decodingFailure(error)
      }
      // Codex can report refresh failure on stderr while returning its bundled catalog successfully.
      // That process retains the fallback; recovery requires a fresh app-server process.
      let diagnostics = String(decoding: await client.stderrSnapshot(), as: UTF8.self)
      if let detail = refreshFailureDetail(diagnostics) {
        return .refreshFailed(detail)
      }
      models.append(contentsOf: page.data)
      guard let next = page.nextCursor, !next.isEmpty, next != cursor else {
        guard Set(models.map(\.id)).count == models.count else {
          throw BridgeMCPQueryError.codexAppServerUnavailable(
            "Codex model/list catalog validation failed (duplicate_identifier at data.id).")
        }
        return .models(models)
      }
      cursor = next
    }
    throw BridgeMCPQueryError.unavailable
  }

  private static func refreshFailureDetail(_ diagnostics: String) -> String? {
    let markers = [
      "failed to refresh available models:",
      "model catalog refresh after auth change failed or timed out",
    ]
    for line in diagnostics.split(whereSeparator: \.isNewline).reversed() {
      for marker in markers {
        guard let range = line.range(of: marker) else { continue }
        return OutboundContentSecurity.redactedSecrets(
          String(line[range.lowerBound...]), maximumUTF8Bytes: 512)
      }
    }
    return nil
  }
}
