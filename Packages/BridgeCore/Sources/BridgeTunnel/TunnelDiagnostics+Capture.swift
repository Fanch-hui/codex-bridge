import Foundation

extension TunnelDiagnostics {
  static func capture(_ child: TunnelSpawnedProcess) -> Self {
    let stdout = child.stdout.snapshot()
    let stderr = child.stderr.snapshot()
    return Self(
      standardOutput: stdout.text,
      standardError: stderr.text,
      wasTruncated: stdout.truncated || stderr.truncated,
      actionRequired: child.stdout.authenticationFailureObserved()
        || child.stderr.authenticationFailureObserved()
        || requiresAuthenticationAction(stdout.text + "\n" + stderr.text)
    )
  }

  func appendingStartupTrace(_ trace: TunnelStartupDiagnostics?) -> Self {
    guard let trace else { return self }
    return Self(
      standardOutput: standardOutput,
      standardError: [standardError, trace.snapshot()].filter { !$0.isEmpty }.joined(
        separator: "\n"),
      wasTruncated: wasTruncated,
      actionRequired: actionRequired
    )
  }

  func recordingCleanupFailure() -> Self {
    Self(
      standardOutput: standardOutput,
      standardError: [standardError, "Tunnel runtime cleanup failed."]
        .filter { !$0.isEmpty }.joined(separator: "\n"),
      wasTruncated: wasTruncated,
      actionRequired: actionRequired
    )
  }

  var combinedOutput: String {
    [standardOutput, standardError].filter { !$0.isEmpty }.joined(separator: "\n")
  }

  private static func requiresAuthenticationAction(_ text: String) -> Bool {
    let lower = text.lowercased()
    let compact = lower.filter { !$0.isWhitespace }
    return lower.contains("unauthorized") || lower.contains("forbidden")
      || compact.contains("\"status\":401") || compact.contains("\"status\":403")
      || compact.contains("\"status_code\":401") || compact.contains("\"status_code\":403")
  }
}
