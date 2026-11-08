import BridgeProcess
import Foundation

struct EmbeddedDSHHostRecord: Codable, Sendable {
  static let fileName = ".bridge-dsh-host.json"
  private static let groupPrefix = "Local\\CodexBridgeDSH-"
  let version: Int
  let groupName: String
  let identity: ManagedProcessIdentity?

  init() {
    version = 1
    groupName = Self.groupPrefix + UUID().uuidString
    identity = nil
  }

  func running(identity: ManagedProcessIdentity) -> Self {
    Self(version: version, groupName: groupName, identity: identity)
  }

  private init(version: Int, groupName: String, identity: ManagedProcessIdentity?) {
    self.version = version
    self.groupName = groupName
    self.identity = identity
  }

  func save(in root: URL) throws {
    do {
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      try JSONEncoder().encode(self).write(
        to: root.appendingPathComponent(Self.fileName), options: .atomic)
    } catch { throw EmbeddedDSHRuntimeError.invalidConfiguration }
  }

  static func clear(in root: URL) -> Bool {
    let url = root.appendingPathComponent(fileName)
    do {
      if try read(in: root) != nil { try FileManager.default.removeItem(at: url) }
      return true
    } catch { return false }
  }

  static func recover(in root: URL) async -> Bool {
    do {
      guard let record = try read(in: root) else { return true }
      guard let identity = record.identity else { return false }
      let confirmed = await Task.detached {
        ManagedStdioProcess.recoverProcessTree(identity: identity, groupName: record.groupName)
      }.value
      return confirmed && clear(in: root)
    } catch { return false }
  }

  private static func read(in root: URL) throws -> Self? {
    let url = root.appendingPathComponent(fileName)
    let attributes: [FileAttributeKey: Any]
    do {
      attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    } catch let error as NSError where error.code == NSFileReadNoSuchFileError {
      return nil
    }
    guard attributes[.type] as? FileAttributeType == .typeRegular,
      let size = attributes[.size] as? NSNumber, size.intValue <= 4096,
      let record = try? JSONDecoder().decode(Self.self, from: Data(contentsOf: url)),
      record.version == 1, record.groupName.hasPrefix(groupPrefix),
      UUID(uuidString: String(record.groupName.dropFirst(groupPrefix.count))) != nil
    else { throw EmbeddedDSHRuntimeError.invalidConfiguration }
    return record
  }
}
