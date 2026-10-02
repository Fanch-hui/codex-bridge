#if os(Linux)
  import BridgeDesktopShell
  import Dispatch
  import Glibc

  let arguments = Array(CommandLine.arguments.dropFirst())
  Task { @MainActor in
    if arguments == ["--ensure-service"] {
      exit(await LinuxApplicationControl.ensureServiceRunning() ? EXIT_SUCCESS : EXIT_FAILURE)
    }
    if arguments == ["--shutdown-service"] {
      exit(await LinuxApplicationControl.shutdownService() ? EXIT_SUCCESS : EXIT_FAILURE)
    }
    guard arguments.isEmpty else { exit(EXIT_FAILURE) }
    await CodexBridgeDesktopApplication.main()
    exit(EXIT_SUCCESS)
  }
  dispatchMain()
#else
  import Foundation

  FileHandle.standardError.write(Data("codex-bridge-linux-app requires Linux.\n".utf8))
  exit(EXIT_FAILURE)
#endif
