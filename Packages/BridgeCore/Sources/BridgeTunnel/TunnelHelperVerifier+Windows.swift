#if os(Windows)
  import BridgeSecurity
  import Crypto
  import Foundation
  import WinSDK

  /// Windows code identity: fixed SHA-256 digest plus PE/COFF architecture.
  /// Dynamic verification re-reads the running process main image through a
  /// reparse-safe handle and compares its digest (no Authenticode).
  public struct WindowsTunnelCodeSignatureVerifier: TunnelCodeSignatureVerifier {
    public init() {}

    public func verifyStatic(executableDescriptor: Int32) throws -> TunnelCodeIdentity {
      throw TunnelHelperError.hostSignatureUnavailable
    }

    public func verifyDynamic(
      processID: Int32,
      expectedIdentity: TunnelCodeIdentity
    ) throws {
      guard let imagePath = WindowsTunnelHelperVerifier.mainImagePath(for: processID) else {
        throw TunnelHelperError.signatureInvalid
      }
      let digest = try WindowsTunnelHelperVerifier.digestOfExecutable(at: imagePath)
      guard digest == expectedIdentity.codeDirectoryHash else {
        throw TunnelHelperError.identityMismatch
      }
    }
  }

  package enum WindowsTunnelHelperVerifier {
    package static let maximumHelperBytes = 1 << 28

    package static func verify(
      executable: URL,
      expectedSHA256: String
    ) throws -> TunnelVerifiedHelper {
      let (handle, metadata) = try openExecutable(executable.path)
      defer { WindowsSecureFile.close(handle) }
      guard metadata.isRegularFile else { throw TunnelHelperError.notRegularFile }
      guard metadata.size > 0, metadata.size <= maximumHelperBytes else {
        throw TunnelHelperError.unavailable
      }
      let data = try readExecutable(handle)
      let digest = digestBytes(of: data)
      guard digestHex(of: digest) == expectedSHA256 else {
        throw TunnelHelperError.digestMismatch
      }
      let architecture = WindowsTunnelExecutable.architecture(ofPrefix: data)
      guard
        WindowsTunnelExecutable.matches(
          architecture,
          native: WindowsTunnelExecutable.nativeArchitecture
        )
      else {
        throw TunnelHelperError.notExecutable
      }
      return TunnelVerifiedHelper(
        executable: executable,
        codeIdentity: TunnelCodeIdentity(codeDirectoryHash: digest)
      )
    }

    package static func mainImagePath(for processID: Int32) -> String? {
      guard processID > 0,
        let handle = OpenProcess(
          DWORD(PROCESS_QUERY_LIMITED_INFORMATION),
          false,
          DWORD(bitPattern: processID)
        )
      else { return nil }
      defer { _ = CloseHandle(handle) }
      var buffer = [WCHAR](repeating: 0, count: 32_768)
      var length = DWORD(buffer.count)
      let succeeded = buffer.withUnsafeMutableBufferPointer { raw in
        QueryFullProcessImageNameW(handle, DWORD(0), raw.baseAddress, &length)
      }
      guard succeeded, length > 0 else { return nil }
      return String(decoding: buffer[..<Int(length)], as: UTF16.self)
    }

    package static func digestOfExecutable(at path: String) throws -> Data {
      let (handle, metadata) = try openExecutable(path)
      defer { WindowsSecureFile.close(handle) }
      guard metadata.isRegularFile, metadata.size > 0, metadata.size <= maximumHelperBytes else {
        throw TunnelHelperError.signatureInvalid
      }
      return digestBytes(of: try readExecutable(handle))
    }

    private static func openExecutable(_ path: String) throws -> (
      HANDLE, WindowsSecureFile.Metadata
    ) {
      do {
        return try WindowsSecureFile.openResolving(
          rootPath: path,
          components: [],
          desiredAccess: DWORD(GENERIC_READ),
          creationDisposition: DWORD(OPEN_EXISTING),
          finalIsDirectory: false
        )
      } catch let error as PathSecurityError {
        if error == .unsupportedFileType { throw TunnelHelperError.notRegularFile }
        throw TunnelHelperError.unavailable
      } catch {
        throw TunnelHelperError.unavailable
      }
    }

    private static func readExecutable(_ handle: HANDLE) throws -> Data {
      do {
        return try WindowsSecureFile.readFile(handle, maximumBytes: maximumHelperBytes)
      } catch {
        throw TunnelHelperError.unavailable
      }
    }

    private static func digestBytes(of data: Data) -> Data {
      Data(SHA256.hash(data: data))
    }

    private static func digestHex(of digest: Data) -> String {
      digest.map { String(format: "%02x", $0) }.joined()
    }
  }
#endif
