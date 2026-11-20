#if os(Windows)
  import WinSDK

  enum WindowsPipeServerIdentity {
    static func expectedServiceImage() -> [WCHAR]? {
      guard let image = imagePath(of: GetCurrentProcess()),
        let separator = image.lastIndex(of: 0x5C)
      else { return nil }
      return Array(image[...separator]) + "codex-bridge-service.exe".utf16
    }

    static func accepts(pipe: HANDLE, expectedImage: [WCHAR]?) -> Bool {
      var pid: ULONG = 0
      guard let expectedImage, GetNamedPipeServerProcessId(pipe, &pid), pid != 0,
        let process = OpenProcess(DWORD(PROCESS_QUERY_LIMITED_INFORMATION), false, pid)
      else { return false }
      defer { _ = CloseHandle(process) }
      return imagePath(of: process) == expectedImage
    }

    // Ask the kernel for both native image paths, rather than comparing drive
    // letters, extended Win32 prefixes, or a path from the peer. Compare raw
    // UTF-16: distinct Unicode names and case-sensitive directories stay distinct.
    static func imagePath(of process: HANDLE) -> [WCHAR]? {
      var buffer = [WCHAR](repeating: 0, count: 32_768)
      var length = DWORD(buffer.count)
      let success = buffer.withUnsafeMutableBufferPointer {
        QueryFullProcessImageNameW(process, DWORD(PROCESS_NAME_NATIVE), $0.baseAddress, &length)
      }
      guard success, length > 0, length < DWORD(buffer.count) else { return nil }
      return Array(buffer.prefix(Int(length)))
    }
  }
#endif
