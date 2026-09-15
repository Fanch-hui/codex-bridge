import BridgeAgentCore
import BridgeCodexRPC
import BridgeServiceCore

extension ExecutionSession {
  func codexProjectID(for project: ServiceProjectRecord) async throws -> String? {
    guard configuration.synchronizeCodexProjects else { return nil }
    var cursor: String?
    var inspected = 0
    do {
      while inspected < configuration.maximumKnownItems {
        let page = try await client.listProjects(
          ProjectListParams(cursor: cursor, limit: 100)
        )
        inspected += page.data.count
        guard inspected <= configuration.maximumKnownItems else {
          throw ExecutionServiceError.protocolViolation("project catalog capacity")
        }
        if let existing = page.data.first(where: { value in
          value.roots.contains { Self.pathsMatch($0.path, projectRoot) }
        }) {
          return try validatedCodexProjectID(existing)
        }
        guard let next = page.nextCursor, !next.isEmpty, next != cursor else { break }
        cursor = next
      }
    } catch let error as CodexRPCError where Self.isUnsupportedProjectAPI(error) {
      return nil
    } catch let error as ExecutionServiceError {
      throw error
    } catch {
      throw ExecutionServiceError.processUnavailable
    }

    do {
      let response = try await client.createProject(
        ProjectCreateParams(
          idempotencyKey: "codex-bridge:" + project.id.rawValue,
          name: project.name,
          roots: [CodexProjectRoot(path: projectRoot)],
          metadata: ["managedBy": "codex_bridge_macos"]
        )
      )
      return try validatedCodexProjectID(response.project, requiresExactRoot: true)
    } catch let error as ExecutionServiceError {
      throw error
    } catch {
      throw ExecutionServiceError.processUnavailable
    }
  }

  private func validatedCodexProjectID(
    _ project: CodexProject,
    requiresExactRoot: Bool = false
  ) throws -> String {
    let paths = project.roots.map(\.path)
    let rootMatches =
      requiresExactRoot
      ? paths.count == 1 && Self.pathsMatch(paths[0], projectRoot)
      : paths.contains { Self.pathsMatch($0, projectRoot) }
    guard Self.isSafeWireIdentifier(project.id), rootMatches else {
      throw ExecutionServiceError.protocolViolation("project binding")
    }
    return project.id
  }

  private static func isUnsupportedProjectAPI(_ error: CodexRPCError) -> Bool {
    guard case .remote(let code, _, _) = error else { return false }
    return code == -32601
  }

  static func pathsMatch(
    _ lhs: String,
    _ rhs: String,
    style: AgentPathStyle = .current
  ) -> Bool {
    guard style == .windows else { return lhs == rhs }
    guard AgentPathSemantics.isAbsolute(lhs, style: .windows),
      AgentPathSemantics.isAbsolute(rhs, style: .windows),
      let left = AgentPathSemantics.canonicalPath(lhs, style: .windows),
      let right = AgentPathSemantics.canonicalPath(rhs, style: .windows)
    else {
      return false
    }
    return left.caseInsensitiveCompare(right) == .orderedSame
  }
}
