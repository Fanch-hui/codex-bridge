import BridgeSecurity
import Foundation

public enum SkillDocumentReader {
  public static func readOccurrence(
    _ occurrence: SkillOccurrence,
    slug: String,
    subpath: String = "SKILL.md",
    maximumBytes: Int = SkillScanner.maximumDocumentBytes,
    fileManager: FileManager = .default
  ) throws -> SkillDocument {
    if occurrence.isFlatFile {
      guard subpath == "SKILL.md" else { throw SkillError.documentNotFound }
      guard maximumBytes > 0, maximumBytes <= SkillScanner.maximumDocumentBytes else {
        throw SkillError.documentTooLarge
      }
      let url = URL(fileURLWithPath: occurrence.entryFilePath).resolvingSymlinksInPath()
        .standardizedFileURL
      guard SkillHubHashing.isSafeResolvedTarget(url),
        let relative = try? SecureRelativePath(url.lastPathComponent),
        SensitivePathPolicy().allows(relative)
      else { throw SkillError.sensitivePath }
      guard let meta = try? FileSystemEntryMetadata(at: url), meta.isRegularFile else {
        throw SkillError.documentNotFound
      }
      if let fileSize = meta.fileSize, fileSize > maximumBytes {
        throw SkillError.documentTooLarge
      }
      let data: Data
      do {
        data = try Data(contentsOf: url)
      } catch {
        throw SkillError.documentNotFound
      }
      guard data.count <= maximumBytes else { throw SkillError.documentTooLarge }
      guard !data.contains(0), let text = String(data: data, encoding: .utf8) else {
        throw SkillError.invalidEncoding
      }
      return SkillDocument(
        name: slug,
        subpath: "SKILL.md",
        content: text,
        byteCount: text.utf8.count
      )
    }
    let manifest = SkillManifest(
      name: slug,
      description: occurrence.description,
      scope: occurrence.scope,
      rootPath: occurrence.canonicalRootPath
    )
    return try read(
      manifest, subpath: subpath, maximumBytes: maximumBytes, fileManager: fileManager)
  }

  static func read(
    _ manifest: SkillManifest,
    subpath: String,
    maximumBytes: Int,
    fileManager: FileManager
  ) throws -> SkillDocument {
    guard maximumBytes > 0, maximumBytes <= SkillScanner.maximumDocumentBytes else {
      throw SkillError.documentTooLarge
    }
    let root = URL(fileURLWithPath: manifest.rootPath).standardizedFileURL
    let relative: SecureRelativePath
    do {
      relative = try SecureRelativePath(subpath)
    } catch {
      throw SkillError.pathEscapeDetected
    }
    guard !relative.components.isEmpty else { throw SkillError.documentNotFound }
    guard SensitivePathPolicy().allows(relative) else { throw SkillError.sensitivePath }
    let target = root.appendingPathComponent(relative.components.joined(separator: "/"))
    guard fileManager.fileExists(atPath: target.path) else { throw SkillError.documentNotFound }

    let document: SecureTextFile
    do {
      let resolver = ProjectPathResolver(root: try RegisteredRoot(capturing: root))
      document = try SecureFileReader(maximumBytes: maximumBytes, maximumLines: .max)
        .read(relative, through: resolver)
    } catch let error as PathSecurityError {
      switch error {
      case .sensitiveFileBlocked:
        throw SkillError.sensitivePath
      case .pathEscapeBlocked, .invalidRelativePath:
        throw SkillError.pathEscapeDetected
      case .pathDoesNotExist, .rootUnavailable:
        throw SkillError.documentNotFound
      case .fileTooLarge:
        throw SkillError.documentTooLarge
      case .binaryFileBlocked:
        throw SkillError.invalidEncoding
      default:
        throw error
      }
    }
    return SkillDocument(
      name: manifest.name,
      subpath: relative.components.joined(separator: "/"),
      content: document.text,
      byteCount: document.byteCount
    )
  }
}
