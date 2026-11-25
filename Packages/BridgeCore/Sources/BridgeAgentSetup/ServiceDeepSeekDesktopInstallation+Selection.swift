import BridgeAgentCore
import BridgeDeepSeekHarnessACP
import BridgeDeepSeekHarnessDesktop
import Foundation

extension ServiceDeepSeekDesktopInstallation {
  func selectInstalledConnector(
    layout: DeepSeekHarnessACPRuntimeLayout, package: URL, environment: [String: String]
  ) async throws -> Bool {
    guard let profile = desktopProfileDirectory(cwd: package) else {
      throw ServiceDeepSeekDesktopInstallError.installationFailed(
        diagnosticCode: "DSH_PROFILE_HOME_INVALID")
    }
    let output = try await runNativeCommand(
      [layout.runtimePath] + layout.runtimeArguments
        + [
          "--input-type=module", "-e", DSHDesktopConnectorSelection.script,
          layout.entryPath, package.path, profile.path,
        ],
      cwd: package, environment: environment,
      timeoutSeconds: AgentSetupProcessLimits.maximumControlSeconds)
    let status = try Self.connectorSelectionStatus(output)
    switch status {
    case .enabled: return true
    case .needsInstall: return false
    case .busy, .incompatible, .unsupported, .failed:
      throw ServiceDeepSeekDesktopInstallError.installationFailed(
        diagnosticCode: status.diagnosticCode)
    }
  }

  static func connectorSelectionStatus(_ output: String) throws -> DSHConnectorSelectionStatus {
    let replies = output.split(whereSeparator: \.isNewline).compactMap { line in
      try? JSONDecoder().decode(DSHConnectorSelectionReply.self, from: Data(line.utf8))
    }
    guard replies.count == 1, let reply = replies.first,
      let status = DSHConnectorSelectionStatus(rawValue: reply.status)
    else {
      throw ServiceDeepSeekDesktopInstallError.installationFailed(
        diagnosticCode: "DSH_CONNECTOR_REPLY_INVALID")
    }
    return status
  }
}

enum DSHConnectorSelectionStatus: String, Decodable {
  case enabled
  case needsInstall = "needs_install"
  case busy
  case incompatible
  case unsupported
  case failed

  var diagnosticCode: String {
    switch self {
    case .enabled, .needsInstall: "DSH_CONNECTOR_INSTALL_INCOMPLETE"
    case .busy: "DSH_PROFILE_BUSY"
    case .incompatible: "DSH_CONNECTOR_INCOMPATIBLE"
    case .unsupported: "DSH_CONNECTOR_API_UNSUPPORTED"
    case .failed: "DSH_CONNECTOR_SELECTION_FAILED"
    }
  }
}

private struct DSHConnectorSelectionReply: Decodable {
  let status: String
}
