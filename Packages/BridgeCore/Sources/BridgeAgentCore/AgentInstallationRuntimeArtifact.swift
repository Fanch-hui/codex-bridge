import Foundation

public enum AgentInstallationRuntimeArtifactRole: String, Codable, Sendable {
  case archive
  case unpackedFile = "unpacked_file"
}

public struct AgentInstallationRuntimeArtifact: Codable, Equatable, Sendable {
  public let role: AgentInstallationRuntimeArtifactRole
  public let canonicalPath: String
  public let device: UInt64
  public let inode: UInt64
  public let fileSize: UInt64
  public let modificationTimeNanoseconds: Int64
  public let sha256: String

  public init(
    role: AgentInstallationRuntimeArtifactRole, canonicalPath: String,
    device: UInt64, inode: UInt64, fileSize: UInt64,
    modificationTimeNanoseconds: Int64, sha256: String
  ) {
    self.role = role
    self.canonicalPath = canonicalPath
    self.device = device
    self.inode = inode
    self.fileSize = fileSize
    self.modificationTimeNanoseconds = modificationTimeNanoseconds
    self.sha256 = sha256
  }

  public static func validate(_ artifacts: [Self]) throws {
    guard artifacts.count <= 4_096,
      Set(artifacts.map(\.canonicalPath)).count == artifacts.count,
      artifacts.allSatisfy({
        AgentPathSemantics.isAbsolute($0.canonicalPath)
          && !$0.canonicalPath.contains("\0") && $0.inode > 0 && $0.fileSize > 0
          && $0.modificationTimeNanoseconds >= 0 && $0.sha256.utf8.count == 64
          && $0.sha256.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
      })
    else { throw AgentRuntimeError.invalidRequest("installation.runtimeArtifacts") }
  }
}

public protocol AgentInstallationRuntimeArtifactProviding: Sendable {
  func installationRuntimeArtifacts(for installation: AgentInstallation) async throws
    -> [AgentInstallationRuntimeArtifact]
}
