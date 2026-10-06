#if os(Windows)
  import BridgeSecurity
  import Foundation
  import WinSDK

  enum DeepSeekHarnessDesktopWindowsIdentity {
    static func readDescriptor(at path: String, maximumBytes: Int) throws -> Data {
      let (handle, metadata) = try WindowsSecureFile.openAbsoluteRegularFileResolving(
        path, desiredAccess: DWORD(GENERIC_READ) | DWORD(READ_CONTROL))
      defer { WindowsSecureFile.close(handle) }
      guard metadata.size <= maximumBytes else { throw SecureFileArtifactError.fileTooLarge }
      var owner: PSID?
      var descriptor: PSECURITY_DESCRIPTOR?
      let result = GetSecurityInfo(
        handle, SE_FILE_OBJECT, DWORD(OWNER_SECURITY_INFORMATION),
        &owner, nil, nil, nil, &descriptor)
      defer { if let descriptor { _ = LocalFree(descriptor) } }
      guard result == ERROR_SUCCESS, let owner,
        try sidData(owner) == processUser(GetCurrentProcess())
      else { throw SecureFileArtifactError.unsafePermissions }
      return try WindowsSecureFile.readFile(handle, maximumBytes: maximumBytes)
    }

    static func processPath(_ pid: Int32) -> String? {
      guard pid > 1,
        let handle = OpenProcess(DWORD(PROCESS_QUERY_LIMITED_INFORMATION), false, DWORD(pid))
      else { return nil }
      defer { _ = CloseHandle(handle) }
      guard let owner = try? processUser(handle),
        let current = try? processUser(GetCurrentProcess()), owner == current
      else { return nil }
      var buffer = [WCHAR](repeating: 0, count: 32_768)
      var length = DWORD(buffer.count)
      let succeeded = buffer.withUnsafeMutableBufferPointer {
        QueryFullProcessImageNameW(handle, DWORD(0), $0.baseAddress, &length)
      }
      guard succeeded, length > 0 else { return nil }
      return String(decoding: buffer.prefix(Int(length)), as: UTF16.self)
    }

    private static func processUser(_ process: HANDLE) throws -> Data {
      var token: HANDLE?
      guard OpenProcessToken(process, DWORD(TOKEN_QUERY), &token), let token else {
        throw SecureFileArtifactError.unsafePermissions
      }
      defer { _ = CloseHandle(token) }
      var required: DWORD = 0
      _ = GetTokenInformation(token, TokenUser, nil, 0, &required)
      guard required > 0 else { throw SecureFileArtifactError.unsafePermissions }
      let buffer = UnsafeMutableRawPointer.allocate(
        byteCount: Int(required), alignment: MemoryLayout<TOKEN_USER>.alignment)
      defer { buffer.deallocate() }
      guard GetTokenInformation(token, TokenUser, buffer, required, &required),
        let sid = buffer.assumingMemoryBound(to: TOKEN_USER.self).pointee.User.Sid
      else { throw SecureFileArtifactError.unsafePermissions }
      return try sidData(sid)
    }

    private static func sidData(_ sid: PSID) throws -> Data {
      guard IsValidSid(sid) else { throw SecureFileArtifactError.unsafePermissions }
      return Data(bytes: sid, count: Int(GetLengthSid(sid)))
    }
  }
#endif
