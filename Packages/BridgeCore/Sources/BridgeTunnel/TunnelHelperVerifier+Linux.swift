#if os(Linux)
  import Crypto
  import Foundation
  import Glibc

  public struct LinuxTunnelCodeSignatureVerifier: TunnelCodeSignatureVerifier {
    public init() {}

    public func verifyStatic(executableDescriptor: Int32) throws -> TunnelCodeIdentity {
      var header = [UInt8](repeating: 0, count: 64)
      guard pread(executableDescriptor, &header, header.count, 0) == header.count,
        Array(header.prefix(6)) == [0x7f, 0x45, 0x4c, 0x46, 2, 1]
      else { throw TunnelHelperError.signatureInvalid }
      let machine = UInt16(header[18]) | UInt16(header[19]) << 8
      #if arch(arm64)
        let expectedMachine: UInt16 = 183
      #else
        let expectedMachine: UInt16 = 62
      #endif
      guard machine == expectedMachine else { throw TunnelHelperError.signatureInvalid }
      let type = UInt16(header[16]) | UInt16(header[17]) << 8
      guard type == 2 || type == 3 else { throw TunnelHelperError.signatureInvalid }
      return TunnelCodeIdentity(codeDirectoryHash: try digest(executableDescriptor))
    }

    public func verifyDynamic(processID: Int32, expectedIdentity: TunnelCodeIdentity) throws {
      let descriptor = open("/proc/\(processID)/exe", O_RDONLY | O_CLOEXEC)
      guard descriptor >= 0 else { throw TunnelHelperError.signatureInvalid }
      defer { close(descriptor) }
      guard try verifyStatic(executableDescriptor: descriptor) == expectedIdentity else {
        throw TunnelHelperError.identityMismatch
      }
    }

    private func digest(_ descriptor: Int32) throws -> Data {
      var hasher = SHA256()
      var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
      var offset: off_t = 0
      while true {
        let count = pread(descriptor, &buffer, buffer.count, offset)
        if count == 0 { break }
        if count < 0, errno == EINTR { continue }
        guard count > 0 else { throw TunnelHelperError.unavailable }
        hasher.update(data: Data(buffer.prefix(count)))
        offset += off_t(count)
      }
      return Data(hasher.finalize())
    }
  }
#endif
