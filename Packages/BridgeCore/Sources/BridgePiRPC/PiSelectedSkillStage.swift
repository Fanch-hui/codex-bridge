import BridgeAgentCore
import BridgeSecurity
import Foundation

struct PiSelectedSkillStage: Sendable {
  let skillDirectories: [String]
  private let resolver: ProjectPathResolver
  private let files: [StagedFile]
  private let directories: [SecureRelativePath]

  private struct StagedFile: Sendable {
    let path: SecureRelativePath
    let sha256: String
  }

  static func directoryPaths(count: Int, runtimeRoot: RegisteredRoot, nonce: String) -> [String] {
    let root = URL(fileURLWithPath: runtimeRoot.canonicalPath, isDirectory: true)
    let namespace = "pi-selected-skills-\(nonce)"
    return (0..<count).map { index in
      root.appending(path: "\(namespace)/\(index)").path
    }
  }

  static func create(
    skills: [AgentSelectedSkill], runtimeRoot: RegisteredRoot, nonce: String
  ) throws -> PiSelectedSkillStage? {
    guard !skills.isEmpty else { return nil }
    let resolver = ProjectPathResolver(root: runtimeRoot)
    var stagedFiles: [StagedFile] = []
    var stagedDirectories: Set<SecureRelativePath> = []
    let namespace = "pi-selected-skills-\(nonce)"
    let writer = SecureProjectFileWriter(maximumBytes: 64 * 1_024)

    do {
      for (index, skill) in skills.enumerated() {
        let skillRoot = try SecureRelativePath("\(namespace)/\(index)")
        addDirectories(for: skillRoot, to: &stagedDirectories)
        for file in skill.files {
          let relativePath = try SecureRelativePath("\(skillRoot.value)/\(file.relativePath)")
          let result = try writer.write(
            relativePath: relativePath, through: resolver, mode: .create,
            content: Data(file.content.utf8), expectedSHA256: nil, createParents: true)
          stagedFiles.append(StagedFile(path: relativePath, sha256: result.newRevision.sha256))
          addDirectories(for: relativePath, to: &stagedDirectories)
        }
      }
      return PiSelectedSkillStage(
        skillDirectories: directoryPaths(
          count: skills.count, runtimeRoot: runtimeRoot, nonce: nonce),
        resolver: resolver, files: stagedFiles,
        directories: stagedDirectories.sorted {
          $0.components.count > $1.components.count
        })
    } catch {
      PiSelectedSkillStage(
        skillDirectories: [], resolver: resolver, files: stagedFiles,
        directories: stagedDirectories.sorted { $0.components.count > $1.components.count }
      ).cleanup()
      throw error
    }
  }

  func cleanup() {
    let mutation = SecureProjectDirectoryMutation(maximumBytes: 64 * 1_024)
    for file in files.reversed() {
      _ = try? mutation.apply(
        action: .deleteFile(expectedSHA256: file.sha256), relativePath: file.path,
        destinationRelativePath: nil, through: resolver)
    }
    for directory in directories {
      _ = try? mutation.apply(
        action: .deleteEmptyDirectory, relativePath: directory,
        destinationRelativePath: nil, through: resolver)
    }
  }

  private static func addDirectories(
    for path: SecureRelativePath, to directories: inout Set<SecureRelativePath>
  ) {
    for count in 1..<path.components.count {
      let prefix = path.components.prefix(count).joined(separator: "/")
      if let directory = try? SecureRelativePath(prefix) { directories.insert(directory) }
    }
  }
}
