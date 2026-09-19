import BridgeSecurity
import Foundation

enum ACPRemoteErrorDiagnostic {
  static func message(for error: ACPWireError) -> String {
    let detail =
      error.data?.stringValue ?? error.data?["message"]?.stringValue
      ?? error.data?["details"]?.stringValue
    var parts = [error.message]
    if let detail, detail != error.message, detail.utf8.count <= 16 * 1_024,
      !detail.contains("\0")
    {
      parts.append(detail)
    }
    return OutboundContentSecurity.redactedSecrets(
      parts.joined(separator: ": "), maximumUTF8Bytes: 4 * 1_024
    )
  }
}
