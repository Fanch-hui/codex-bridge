import BridgeServiceHost
import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#elseif os(Windows)
  import ucrt
#endif

#if os(Windows)
  import WinSDK

  /// Locks the service's DLL search to System32 and its own application
  /// directory. The default search order also walks the current directory
  /// and legacy PATH locations, so a DLL planted next to data files would
  /// load into the long-running service; this removes every fallback.
  private enum WindowsDllSearchPolicy {
    static func applyDefaultLockdown() -> Bool {
      SetDefaultDllDirectories(
        UINT(LOAD_LIBRARY_SEARCH_SYSTEM32 | LOAD_LIBRARY_SEARCH_APPLICATION_DIR))
    }
  }
#endif

@main
enum CodexBridgeServiceMain {
  static func main() async {
    #if os(Windows)
      // Fail closed: without the lockdown the service would run with the
      // legacy search order (current directory and PATH walk), which is the
      // exact exposure the lockdown removes, so refuse to start.
      guard WindowsDllSearchPolicy.applyDefaultLockdown() else {
        FileHandle.standardError.write(
          Data("Codex Bridge service could not lock its DLL search order.\n".utf8))
        _exit(EXIT_FAILURE)
      }
    #endif
    do {
      try await ServiceProcessRunner.run()
    } catch {
      let errorValue = String(reflecting: error)
      let detail = (error as? any LocalizedError)?.errorDescription ?? error.localizedDescription
      FileHandle.standardError.write(
        Data("Codex Bridge service failed to start (\(errorValue)): \(detail)\n".utf8)
      )
      #if os(Windows)
        _exit(EXIT_FAILURE)
      #else
        exit(EXIT_FAILURE)
      #endif
    }
  }
}
