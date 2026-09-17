import BridgeAgentCore
import Foundation

#if os(Windows)
  import WinSDK
#endif

enum DeepSeekHarnessACPDirectoryLink {
  static func createDirectoryLink(
    atPath linkPath: String,
    destinationPath: String
  ) throws {
    guard !linkPath.isEmpty, !destinationPath.isEmpty,
      AgentPathSemantics.isAbsolute(linkPath),
      AgentPathSemantics.isAbsolute(destinationPath)
    else {
      throw AgentRuntimeError.processUnavailable
    }

    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: destinationPath, isDirectory: &isDir),
      isDir.boolValue
    else {
      throw AgentRuntimeError.processUnavailable
    }

    if FileManager.default.fileExists(atPath: linkPath) {
      throw AgentRuntimeError.processUnavailable
    }

    #if os(Windows)
      guard linkPath.count >= 3, destinationPath.count >= 3,
        !linkPath.hasPrefix("\\\\"), !destinationPath.hasPrefix("\\\\")
      else {
        throw AgentRuntimeError.processUnavailable
      }
      let normLink = linkPath.replacingOccurrences(of: "/", with: "\\")
      let normDest = destinationPath.replacingOccurrences(of: "/", with: "\\")

      do {
        try FileManager.default.createSymbolicLink(atPath: normLink, withDestinationPath: normDest)
        return
      } catch {
        try createJunction(atPath: normLink, destinationPath: normDest)
      }
    #else
      try FileManager.default.createSymbolicLink(
        atPath: linkPath,
        withDestinationPath: destinationPath
      )
    #endif
  }

  static func removeDirectoryLink(atPath linkPath: String) {
    guard !linkPath.isEmpty, AgentPathSemantics.isAbsolute(linkPath) else { return }
    #if os(Windows)
      let normLink = linkPath.replacingOccurrences(of: "/", with: "\\")
      normLink.withCString(encodedAs: UTF16.self) { pathPointer in
        let attrs = GetFileAttributesW(pathPointer)
        if attrs != INVALID_FILE_ATTRIBUTES && (attrs & DWORD(FILE_ATTRIBUTE_REPARSE_POINT) != 0) {
          _ = RemoveDirectoryW(pathPointer)
        } else {
          try? FileManager.default.removeItem(atPath: normLink)
        }
      }
    #else
      try? FileManager.default.removeItem(atPath: linkPath)
    #endif
  }

  #if os(Windows)
    private static let fsctlSetReparsePoint: DWORD = 0x0009_00A4
    private static let ioReparseTagMountPoint: DWORD = 0xA000_0003

    private static func createJunction(atPath linkPath: String, destinationPath: String) throws {
      let created = linkPath.withCString(encodedAs: UTF16.self) { CreateDirectoryW($0, nil) }
      guard created else {
        throw AgentRuntimeError.processUnavailable
      }

      let handle = linkPath.withCString(encodedAs: UTF16.self) { pathPointer in
        CreateFileW(
          pathPointer,
          DWORD(GENERIC_READ) | DWORD(GENERIC_WRITE),
          DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE),
          nil,
          DWORD(OPEN_EXISTING),
          DWORD(FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT),
          nil
        )
      }
      guard let handle, handle != INVALID_HANDLE_VALUE else {
        _ = linkPath.withCString(encodedAs: UTF16.self) { RemoveDirectoryW($0) }
        throw AgentRuntimeError.processUnavailable
      }
      defer { _ = CloseHandle(handle) }

      let substitute = "\\??\\" + destinationPath
      let printName = destinationPath

      var subChars = Array(substitute.utf16)
      subChars.append(0)
      var printChars = Array(printName.utf16)
      printChars.append(0)

      let subLen = UInt16((subChars.count - 1) * 2)
      let subOffset: UInt16 = 0
      let printOffset = UInt16(subChars.count * 2)
      let printLen = UInt16((printChars.count - 1) * 2)
      let pathBufferBytes = UInt16((subChars.count + printChars.count) * 2)

      let reparseDataLength = UInt16(8 + pathBufferBytes)
      let totalBufferSize = 8 + Int(reparseDataLength)

      var buffer = [UInt8](repeating: 0, count: totalBufferSize)
      buffer.withUnsafeMutableBytes { raw in
        raw.storeBytes(of: ioReparseTagMountPoint, toByteOffset: 0, as: DWORD.self)
        raw.storeBytes(of: reparseDataLength, toByteOffset: 4, as: UInt16.self)
        raw.storeBytes(of: UInt16(0), toByteOffset: 6, as: UInt16.self)
        raw.storeBytes(of: subOffset, toByteOffset: 8, as: UInt16.self)
        raw.storeBytes(of: subLen, toByteOffset: 10, as: UInt16.self)
        raw.storeBytes(of: printOffset, toByteOffset: 12, as: UInt16.self)
        raw.storeBytes(of: printLen, toByteOffset: 14, as: UInt16.self)

        let pathDest = raw.baseAddress!.advanced(by: 16)
        subChars.withUnsafeBytes { subRaw in
          pathDest.copyMemory(from: subRaw.baseAddress!, byteCount: subRaw.count)
        }
        let printDest = pathDest.advanced(by: subChars.count * 2)
        printChars.withUnsafeBytes { printRaw in
          printDest.copyMemory(from: printRaw.baseAddress!, byteCount: printRaw.count)
        }
      }

      var bytesReturned: DWORD = 0
      let success = buffer.withUnsafeMutableBytes { raw in
        DeviceIoControl(
          handle,
          fsctlSetReparsePoint,
          raw.baseAddress,
          DWORD(totalBufferSize),
          nil,
          0,
          &bytesReturned,
          nil
        )
      }

      if !success {
        _ = linkPath.withCString(encodedAs: UTF16.self) { RemoveDirectoryW($0) }
        throw AgentRuntimeError.processUnavailable
      }
    }
  #endif
}
