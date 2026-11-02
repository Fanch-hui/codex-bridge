import BridgeACP
import BridgeServiceCore
import Foundation

extension ServiceEmbeddedDSHController {
  func projectFileReferences(_ payload: [String: ACPJSONValue]) async throws -> ACPJSONValue {
    let projectID = try Self.requiredString(payload, "projectID")
    _ = try await registeredProject(projectID)
    let query = payload["query"]?.stringValue ?? ""
    guard query.utf8.count <= 2_048, !query.contains("\0"), !query.hasPrefix("/"),
      !query.contains("\\"), !query.split(separator: "/").contains("..")
    else {
      throw ServiceStoreError.invalidArgument("workbench.file_reference")
    }
    let separator = query.lastIndex(of: "/")
    let directory = separator.map { String(query[..<$0]) }.flatMap { $0.isEmpty ? nil : $0 }
    let fragment = separator.map { String(query[query.index(after: $0)...]) } ?? query
    var cursor = payload["cursor"]?.stringValue
    var matches: [ACPJSONValue] = []
    for _ in 0..<5 {
      let page = try await application.serviceListProjectDirectory(
        projectID: projectID,
        relativeDirectory: directory, depth: 1, kind: "all", cursor: cursor,
        limit: 20 - matches.count,
        deadline: .now.advanced(by: .seconds(10)))
      matches += page.entries.filter {
        fragment.isEmpty
          || URL(fileURLWithPath: $0.relativePath).lastPathComponent
            .localizedCaseInsensitiveContains(fragment)
      }.map { entry in
        .object(["path": .string(entry.relativePath), "kind": .string(entry.kind)])
      }
      cursor = page.nextCursor
      if cursor == nil || matches.count == 20 { break }
    }
    return .object([
      "items": .array(matches), "hasMore": .bool(cursor != nil),
      "cursor": cursor.map(ACPJSONValue.string) ?? .null,
    ])
  }
}
