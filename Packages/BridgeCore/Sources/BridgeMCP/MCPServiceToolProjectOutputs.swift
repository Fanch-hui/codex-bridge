struct ServiceGetProjectOutput: Codable, Sendable {
  let schemaVersion = 1
  let project: ServiceProjectDetailOutput

  init(project: MCPProjectDetail) {
    self.project = ServiceProjectDetailOutput(project: project)
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case project
  }
}

struct ServiceProjectDetailOutput: Codable, Sendable {
  let projectID: String
  let name: String
  let gitState: String?
  let threadCount: Int?

  init(project: MCPProjectDetail) {
    projectID = project.projectID
    name = project.name
    gitState = project.gitState
    threadCount = project.threadCount
  }

  private enum CodingKeys: String, CodingKey {
    case projectID = "project_id"
    case name
    case gitState = "git_state"
    case threadCount = "thread_count"
  }
}

struct ServiceProjectChangesOutput: Codable, Sendable {
  let schemaVersion = 1
  let changedFiles: [String]
  let diff: String
  let additions: Int
  let deletions: Int
  let truncated: Bool
  let notGitRepository: Bool

  init(changes: MCPProjectChanges) {
    changedFiles = changes.changedFiles
    diff = changes.diff
    additions = changes.additions
    deletions = changes.deletions
    truncated = changes.truncated
    notGitRepository = changes.notGitRepository
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case changedFiles = "changed_files"
    case diff
    case additions
    case deletions
    case truncated
    case notGitRepository = "not_git_repository"
  }
}
