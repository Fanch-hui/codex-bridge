import BridgeSecurity
import Foundation

enum SkillDocumentReader {
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
