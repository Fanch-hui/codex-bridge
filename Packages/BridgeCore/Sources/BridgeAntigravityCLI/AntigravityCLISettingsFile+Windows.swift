#if os(Windows)
  import BridgeAgentCore
  import Foundation
  import WinSDK

  extension AntigravityCLISettingsFile {
    func read() throws -> Contents? {
      guard FileManager.default.fileExists(atPath: settingsPath) else { return nil }
      var identity = Identity(device: 0, inode: 0)
      let data: Data
      do {
        data = try Data(contentsOf: URL(fileURLWithPath: settingsPath))
      } catch {
        throw AgentNativePermissionPolicyError.settingsUnsafe
      }
      guard data.count <= AntigravityCLISettingsDocument.maximumBytes else {
        throw AgentNativePermissionPolicyError.settingsInvalid
      }
      settingsPath.withCString(encodedAs: UTF16.self) { pathPtr in
        let handle = CreateFileW(
          pathPtr,
          GENERIC_READ,
          DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE),
          nil,
          DWORD(OPEN_EXISTING),
          DWORD(FILE_ATTRIBUTE_NORMAL),
          nil
        )
        if handle != INVALID_HANDLE_VALUE {
          var info = BY_HANDLE_FILE_INFORMATION()
          if GetFileInformationByHandle(handle, &info) {
            identity = Identity(
              device: UInt64(info.dwVolumeSerialNumber),
              inode: (UInt64(info.nFileIndexHigh) << 32) | UInt64(info.nFileIndexLow)
            )
          }
          CloseHandle(handle)
        }
      }
      // Windows uses ACLs
      return Contents(data: data, mode: 0o600, identity: identity)
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
      let stagingPath = parent + "\\.codexbridge-settings-\(UUID().uuidString.lowercased())"
      do {
        try data.write(to: URL(fileURLWithPath: stagingPath), options: .atomic)
      } catch {
        throw AgentNativePermissionPolicyError.settingsUnsafe
      }
      var removeStaging = true
      defer {
        if removeStaging {
          try? FileManager.default.removeItem(atPath: stagingPath)
        }
      }
      let latest = try read()
      guard revision(of: latest) == expectedRevision,
        latest?.identity == expectedIdentity
      else {
        throw AgentNativePermissionPolicyError.revisionConflict
      }
      let success = stagingPath.withCString(encodedAs: UTF16.self) { srcPtr in
        settingsPath.withCString(encodedAs: UTF16.self) { dstPtr in
          MoveFileExW(srcPtr, dstPtr, DWORD(MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH))
        }
      }
      guard success else {
        throw AgentNativePermissionPolicyError.settingsUnsafe
      }
      removeStaging = false
      guard revision(of: try read()) == AntigravityCLISettingsDocument.digest(data) else {
        throw AgentNativePermissionPolicyError.settingsUnsafe
      }
    }

    private func prepareParentDirectory() throws -> String {
      let gemini = homeDirectory + "\\.gemini"
      let parent = gemini + "\\antigravity-cli"
      do {
        try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
      } catch {
        throw AgentNativePermissionPolicyError.settingsUnsafe
      }
      return parent
    }
  }
#endif
