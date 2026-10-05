#if os(Linux)
  import BridgeIPC
  import Foundation

  enum LinuxPackageMaintenance {
    static func requireAvailable() throws {
      guard LinuxServiceEndpoint.executableURL()?.path == "/opt/codex-bridge/codex-bridge-service"
      else { return }
      if FileManager.default.fileExists(atPath: "/opt/codex-bridge/.package-maintenance") {
        throw MaintenanceError.packageUpdating
      }
    }

    private enum MaintenanceError: LocalizedError {
      case packageUpdating

      var errorDescription: String? {
        "Codex Bridge is being updated. Start the service after package installation finishes."
      }
    }
  }
#endif
