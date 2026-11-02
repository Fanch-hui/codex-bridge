import Foundation

/// Associates processes launched in a task with a service-owned recovery directory.
public struct ManagedProcessOwnershipScope: Sendable {
  private let ownerDirectory: URL

  public init(directory: URL, ownerID: String) throws {
    guard directory.isFileURL, !ownerID.isEmpty, ownerID.utf8.count <= 128,
      ownerID.rangeOfCharacter(from: .controlCharacters) == nil
    else { throw ManagedProcessError.invalidArgument }
    let name = Data(ownerID.utf8).base64EncodedString()
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "=", with: "")
    ownerDirectory = directory.standardizedFileURL.appendingPathComponent(name, isDirectory: true)
  }

  /// The caller must prevent new launches for this owner while recovery is in progress.
  /// Returns true only when all recorded process trees have stopped.
  public func recover() -> Bool {
    let fileManager = FileManager.default
    let entries: [URL]
    do {
      let attributes = try fileManager.attributesOfItem(atPath: ownerDirectory.path)
      guard attributes[.type] as? FileAttributeType == .typeDirectory else { return false }
      entries = try fileManager.contentsOfDirectory(
        at: ownerDirectory, includingPropertiesForKeys: nil)
    } catch let error as NSError where error.code == NSFileReadNoSuchFileError {
      return true
    } catch { return false }
    for url in entries {
      guard let record = try? ManagedProcessOwnershipRecord.read(at: url),
        record.recover(), record.remove()
      else { return false }
    }
    return true
  }

  func prepareLaunch() throws -> ManagedProcessOwnershipRecord {
    let fileManager = FileManager.default
    #if os(Windows)
      try fileManager.createDirectory(at: ownerDirectory, withIntermediateDirectories: true)
    #else
      try fileManager.createDirectory(
        at: ownerDirectory, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
    #endif
    let attributes = try fileManager.attributesOfItem(atPath: ownerDirectory.path)
    guard attributes[.type] as? FileAttributeType == .typeDirectory else {
      throw ManagedProcessError.invalidArgument
    }
    let record = ManagedProcessOwnershipRecord(directory: ownerDirectory)
    try record.save(identity: nil)
    return record
  }
}

public enum ManagedProcessOwnership {
  @TaskLocal public static var current: ManagedProcessOwnershipScope?
}

struct ManagedProcessOwnershipRecord: Sendable {
  private struct Contents: Codable {
    let version: Int
    let groupName: String
    let identity: ManagedProcessIdentity?
  }

  private static let groupPrefix = "Local\\CodexBridgeTask-"
  let url: URL
  let groupName: String
  let identity: ManagedProcessIdentity?

  init(directory: URL) {
    let id = UUID().uuidString
    url = directory.appendingPathComponent(id + ".json")
    groupName = Self.groupPrefix + id
    identity = nil
  }

  private init(url: URL, groupName: String, identity: ManagedProcessIdentity?) {
    self.url = url
    self.groupName = groupName
    self.identity = identity
  }

  func save(identity: ManagedProcessIdentity?) throws {
    let content = Contents(version: 1, groupName: groupName, identity: identity)
    try JSONEncoder().encode(content).write(to: url, options: .atomic)
  }

  static func read(at url: URL) throws -> Self {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    let id = url.deletingPathExtension().lastPathComponent
    guard url.pathExtension == "json", UUID(uuidString: id) != nil,
      attributes[.type] as? FileAttributeType == .typeRegular,
      let size = attributes[.size] as? NSNumber, size.intValue <= 4096
    else { throw ManagedProcessError.invalidArgument }
    let content = try JSONDecoder().decode(Contents.self, from: Data(contentsOf: url))
    guard content.version == 1, content.groupName == groupPrefix + id else {
      throw ManagedProcessError.invalidArgument
    }
    return Self(url: url, groupName: content.groupName, identity: content.identity)
  }

  func recover() -> Bool {
    if let identity {
      return ManagedStdioProcess.recoverProcessTree(identity: identity, groupName: groupName)
    }
    #if os(Windows)
      return ManagedWindowsProcessJob.recover(name: groupName)
    #else
      // The launch gate prevents a pending process from executing the target.
      return true
    #endif
  }

  @discardableResult
  func remove() -> Bool {
    do {
      try FileManager.default.removeItem(at: url)
      return true
    } catch let error as NSError
      where error.domain == NSCocoaErrorDomain
      && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code)
    {
      return true
    } catch { return false }
  }
}
