import Foundation

/// Native-image checks for the Windows Tunnel helper.
///
/// Pure byte logic over the PE/COFF header so the rules are exercisable on any
/// host; the Windows caller feeds bytes read through a reparse-safe handle.
package enum WindowsTunnelExecutableArchitecture: Equatable, Sendable {
  case amd64
  case arm64
  case arm64X
  case unsupported(UInt16)
  case invalidHeader
}

package enum WindowsTunnelExecutable {
  package static let imageFileMachineAMD64: UInt16 = 0x8664
  package static let imageFileMachineARM64: UInt16 = 0xAA64
  package static let imageFileMachineARM64X: UInt16 = 0xA641
  private static let imageFileExecutableImage: UInt16 = 0x0002
  private static let newExecutableHeaderOffset = 0x3C
  private static let maximumHeaderOffset = 1_048_576

  /// The architecture a correctly staged helper must declare on this host.
  package static var nativeArchitecture: WindowsTunnelExecutableArchitecture? {
    #if arch(arm64)
      return .arm64
    #elseif arch(x86_64)
      return .amd64
    #else
      return nil
    #endif
  }

  package static func architecture(ofPrefix prefix: Data) -> WindowsTunnelExecutableArchitecture {
    let bytes = [UInt8](prefix)
    guard bytes.count >= 0x40,
      bytes[0] == 0x4D,
      bytes[1] == 0x5A,
      let offset = littleEndianUInt32(bytes, at: newExecutableHeaderOffset),
      offset <= UInt32(maximumHeaderOffset),
      let header = Int(exactly: offset),
      header >= 0x40,
      bytes.count >= header + 24,
      Array(bytes[header..<(header + 4)]) == [0x50, 0x45, 0x00, 0x00],
      let machine = littleEndianUInt16(bytes, at: header + 4),
      let characteristics = littleEndianUInt16(bytes, at: header + 22),
      characteristics & imageFileExecutableImage != 0
    else {
      return .invalidHeader
    }
    switch machine {
    case imageFileMachineAMD64: return .amd64
    case imageFileMachineARM64: return .arm64
    case imageFileMachineARM64X: return .arm64X
    default: return .unsupported(machine)
    }
  }

  /// ARM64X binaries carry ARM64 code and are accepted only on ARM64 hosts.
  package static func matches(
    _ architecture: WindowsTunnelExecutableArchitecture,
    native: WindowsTunnelExecutableArchitecture?
  ) -> Bool {
    guard let native else { return false }
    switch native {
    case .amd64: return architecture == .amd64
    case .arm64: return architecture == .arm64 || architecture == .arm64X
    default: return false
    }
  }

  private static func littleEndianUInt16(_ bytes: [UInt8], at offset: Int) -> UInt16? {
    guard offset >= 0, offset <= bytes.count - 2 else { return nil }
    return UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
  }

  private static func littleEndianUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32? {
    guard offset >= 0, offset <= bytes.count - 4 else { return nil }
    return UInt32(bytes[offset])
      | UInt32(bytes[offset + 1]) << 8
      | UInt32(bytes[offset + 2]) << 16
      | UInt32(bytes[offset + 3]) << 24
  }
}
