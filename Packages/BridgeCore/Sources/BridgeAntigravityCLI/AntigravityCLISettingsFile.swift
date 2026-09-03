import BridgeAgentCore
import Darwin
import Foundation

struct AntigravityCLISettingsFile: Sendable {
  struct Identity: Equatable, Sendable {
    let device: dev_t
    let inode: ino_t
  }

  struct Contents: Sendable {
    let data: Data
    let mode: mode_t
    let identity: Identity
  }

  let homeDirectory: String
  let settingsPath: String

  init(sourceEnvironment: [String: String]) throws {
    let home = try AgentProviderEnvironment.homeDirectory(source: sourceEnvironment)
    homeDirectory = home
    settingsPath =
      URL(fileURLWithPath: home, isDirectory: true)
      .appendingPathComponent(".gemini/antigravity-cli/settings.json", isDirectory: false)
      .standardizedFileURL.path
  }

  func read() throws -> Contents? {
    var pathMetadata = stat()
    guard lstat(settingsPath, &pathMetadata) == 0 else {
      if errno == ENOENT { return nil }
      throw AgentNativePermissionPolicyError.settingsUnsafe
    }
    try validate(metadata: pathMetadata)
    let descriptor = open(settingsPath, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else { throw AgentNativePermissionPolicyError.settingsUnsafe }
    defer { close(descriptor) }
    var descriptorMetadata = stat()
    guard fstat(descriptor, &descriptorMetadata) == 0,
      descriptorMetadata.st_dev == pathMetadata.st_dev,
      descriptorMetadata.st_ino == pathMetadata.st_ino
    else {
      throw AgentNativePermissionPolicyError.settingsUnsafe
    }
    try validate(metadata: descriptorMetadata)
    guard descriptorMetadata.st_size >= 0,
      descriptorMetadata.st_size <= AntigravityCLISettingsDocument.maximumBytes
    else {
      throw AgentNativePermissionPolicyError.settingsInvalid
    }
    return Contents(
      data: try readAll(descriptor),
      mode: descriptorMetadata.st_mode & 0o777,
      identity: Identity(
        device: descriptorMetadata.st_dev,
        inode: descriptorMetadata.st_ino
      )
    )
  }

  func write(
    _ data: Data,
    expectedRevision: String?,
    expectedIdentity: Identity?
  ) throws {
    let initial = try read()
    guard revision(of: initial) == expectedRevision,
      initial?.identity == expectedIdentity
    else {
      throw AgentNativePermissionPolicyError.revisionConflict
    }
    let parent = try prepareParentDirectory()
    let checked = try read()
    guard revision(of: checked) == expectedRevision,
      checked?.identity == expectedIdentity
    else {
      throw AgentNativePermissionPolicyError.revisionConflict
    }
    let stagingPath = parent + "/.codexbridge-settings-\(UUID().uuidString.lowercased())"
    let descriptor = open(
      stagingPath,
      O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
      0o600
    )
    guard descriptor >= 0 else { throw AgentNativePermissionPolicyError.settingsUnsafe }
    var removeStaging = true
    defer {
      close(descriptor)
      if removeStaging { unlink(stagingPath) }
    }
    let mode = checked?.mode ?? 0o600
    guard fchmod(descriptor, mode) == 0 else {
      throw AgentNativePermissionPolicyError.settingsUnsafe
    }
    try writeAll(descriptor, data: data)
    guard fsync(descriptor) == 0 else {
      throw AgentNativePermissionPolicyError.settingsUnsafe
    }
    let latest = try read()
    guard revision(of: latest) == expectedRevision,
      latest?.identity == expectedIdentity
    else {
      throw AgentNativePermissionPolicyError.revisionConflict
    }
    guard rename(stagingPath, settingsPath) == 0 else {
      throw AgentNativePermissionPolicyError.settingsUnsafe
    }
    removeStaging = false
    let parentDescriptor = open(parent, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard parentDescriptor >= 0 else { throw AgentNativePermissionPolicyError.settingsUnsafe }
    defer { close(parentDescriptor) }
    guard fsync(parentDescriptor) == 0 else {
      throw AgentNativePermissionPolicyError.settingsUnsafe
    }
    guard revision(of: try read()) == AntigravityCLISettingsDocument.digest(data) else {
      throw AgentNativePermissionPolicyError.settingsUnsafe
    }
  }

  private func prepareParentDirectory() throws -> String {
    try validateDirectory(homeDirectory)
    let gemini = homeDirectory + "/.gemini"
    let parent = gemini + "/antigravity-cli"
    try createDirectoryIfNeeded(gemini)
    try createDirectoryIfNeeded(parent)
    return parent
  }

  private func createDirectoryIfNeeded(_ path: String) throws {
    if mkdir(path, 0o700) != 0, errno != EEXIST {
      throw AgentNativePermissionPolicyError.settingsUnsafe
    }
    try validateDirectory(path)
  }

  private func validateDirectory(_ path: String) throws {
    var metadata = stat()
    guard lstat(path, &metadata) == 0,
      metadata.st_mode & S_IFMT == S_IFDIR,
      metadata.st_uid == getuid(),
      metadata.st_mode & mode_t(S_IWGRP | S_IWOTH) == 0
    else {
      throw AgentNativePermissionPolicyError.settingsUnsafe
    }
  }

  private func validate(metadata: stat) throws {
    guard metadata.st_mode & S_IFMT == S_IFREG,
      metadata.st_uid == getuid(),
      metadata.st_mode & mode_t(S_IWGRP | S_IWOTH) == 0
    else {
      throw AgentNativePermissionPolicyError.settingsUnsafe
    }
  }

  private func revision(of contents: Contents?) -> String? {
    contents.map { AntigravityCLISettingsDocument.digest($0.data) }
  }

  private func readAll(_ descriptor: Int32) throws -> Data {
    var result = Data()
    var buffer = [UInt8](repeating: 0, count: 16 * 1_024)
    while true {
      let count = Darwin.read(descriptor, &buffer, buffer.count)
      if count == 0 { return result }
      if count < 0 {
        if errno == EINTR { continue }
        throw AgentNativePermissionPolicyError.settingsUnsafe
      }
      result.append(contentsOf: buffer.prefix(count))
      guard result.count <= AntigravityCLISettingsDocument.maximumBytes else {
        throw AgentNativePermissionPolicyError.settingsInvalid
      }
    }
  }

  private func writeAll(_ descriptor: Int32, data: Data) throws {
    try data.withUnsafeBytes { buffer in
      var offset = 0
      while offset < buffer.count {
        let count = Darwin.write(
          descriptor,
          buffer.baseAddress!.advanced(by: offset),
          buffer.count - offset
        )
        if count < 0 {
          if errno == EINTR { continue }
          throw AgentNativePermissionPolicyError.settingsUnsafe
        }
        guard count > 0 else { throw AgentNativePermissionPolicyError.settingsUnsafe }
        offset += count
      }
    }
  }
}
