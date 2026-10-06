#if os(Windows) || os(Linux)
  import BridgeIPC
  import BridgeServiceAppCore
  import Foundation
  #if os(Windows)
    import WinSDK
  #endif

  private enum DeepSeekDesktopWindowError: Error, LocalizedError {
    case unsupportedPlatform
    var errorDescription: String? { "此平台暂不支持 DSH 原生桌面窗口。" }
  }

  extension DesktopPlatformHost {
    static func openDeepSeekDesktop(executablePath: String) throws {
      #if os(Windows)
        guard !executablePath.contains("\0"), executablePath.lowercased().hasSuffix(".exe"),
          FileManager.default.fileExists(atPath: executablePath)
        else { throw BridgeServiceClientError.unavailable }
        let result = "open".withCString(encodedAs: UTF16.self) { operation in
          executablePath.withCString(encodedAs: UTF16.self) { executable in
            ShellExecuteW(nil, operation, executable, nil, nil, SW_SHOWNORMAL)
          }
        }
        guard let result, UInt(bitPattern: result) > 32 else {
          throw BridgeServiceClientError.unavailable
        }
      #else
        throw DeepSeekDesktopWindowError.unsupportedPlatform
      #endif
    }
  }
#endif
