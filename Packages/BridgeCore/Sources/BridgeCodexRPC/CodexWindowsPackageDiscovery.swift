#if os(Windows)
  import Foundation
  import WinSDK

  enum CodexWindowsPackageDiscovery {
    static func installationDirectories() -> [String] {
      "OpenAI.Codex_2p2nqsd0c76g0".withCString(encodedAs: UTF16.self) { family in
        packageNames(in: family)
          .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
          .compactMap(installationDirectory)
      }
    }

    private static func packageNames(in family: UnsafePointer<WCHAR>) -> [String] {
      var count: UINT32 = 0
      var length: UINT32 = 0
      let result = GetPackagesByPackageFamily(family, &count, nil, &length, nil)
      guard result == LONG(ERROR_INSUFFICIENT_BUFFER), count > 0, length > 0 else { return [] }
      var names = [UnsafeMutablePointer<WCHAR>?](repeating: nil, count: Int(count))
      var storage = [WCHAR](repeating: 0, count: Int(length))
      return names.withUnsafeMutableBufferPointer { pointers in
        storage.withUnsafeMutableBufferPointer { buffer in
          guard
            GetPackagesByPackageFamily(
              family, &count, pointers.baseAddress, &length, buffer.baseAddress)
              == LONG(ERROR_SUCCESS)
          else { return [] }
          return pointers.prefix(Int(count)).compactMap { name in
            name.map { String(decodingCString: $0, as: UTF16.self) }
          }
        }
      }
    }

    private static func installationDirectory(_ packageName: String) -> String? {
      packageName.withCString(encodedAs: UTF16.self) { name in
        var length: UINT32 = 0
        guard GetPackagePathByFullName(name, &length, nil) == LONG(ERROR_INSUFFICIENT_BUFFER),
          length > 0
        else { return nil }
        var path = [WCHAR](repeating: 0, count: Int(length))
        guard GetPackagePathByFullName(name, &length, &path) == LONG(ERROR_SUCCESS) else {
          return nil
        }
        return String(decoding: path.prefix(Int(length) - 1), as: UTF16.self)
      }
    }
  }
#endif
