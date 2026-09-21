import Foundation

#if os(macOS)
  import Security

  enum LocalAppPeerIdentity {
    static func accepts(
      processID: pid_t, serviceExecutableURL: URL? = Bundle.main.executableURL
    ) -> Bool {
      guard processID > 0, let executable = serviceExecutableURL else { return false }
      let service = executable.resolvingSymlinksInPath()
      let directory = service.deletingLastPathComponent()
      let app =
        directory.lastPathComponent == "Resources"
          && directory.deletingLastPathComponent().lastPathComponent == "Contents"
        ? directory.deletingLastPathComponent()
          .appendingPathComponent("MacOS/CodexBridge")
        : directory.appendingPathComponent("CodexBridge")
      var guest: SecCode?
      let attributes = [kSecGuestAttributePid: NSNumber(value: processID)] as CFDictionary
      guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &guest) == errSecSuccess,
        let guest
      else { return false }
      var staticGuest: SecStaticCode?
      guard SecCodeCopyStaticCode(guest, [], &staticGuest) == errSecSuccess,
        let staticGuest
      else { return false }
      var expected: SecStaticCode?
      var requirement: SecRequirement?
      var actualURL: CFURL?
      var expectedURL: CFURL?
      guard SecStaticCodeCreateWithPath(app as CFURL, [], &expected) == errSecSuccess,
        let expected,
        SecCodeCopyPath(staticGuest, [], &actualURL) == errSecSuccess,
        SecCodeCopyPath(expected, [], &expectedURL) == errSecSuccess,
        let actualURL, let expectedURL,
        (actualURL as URL).resolvingSymlinksInPath()
          == (expectedURL as URL).resolvingSymlinksInPath(),
        SecCodeCopyDesignatedRequirement(expected, [], &requirement) == errSecSuccess,
        let requirement
      else { return false }
      return SecCodeCheckValidity(guest, [], requirement) == errSecSuccess
    }
  }
#elseif os(Windows)
  import WinSDK

  enum LocalAppPeerIdentity {
    static func accepts(pipe: HANDLE) -> Bool {
      var processID: ULONG = 0
      guard GetNamedPipeClientProcessId(pipe, &processID),
        let actual = WindowsProcessIdentity.imagePath(for: UInt32(processID)),
        let service = try? WindowsProcessIdentity.currentImagePath()
      else { return false }
      let directory = URL(fileURLWithPath: service).deletingLastPathComponent()
      let app = directory.appendingPathComponent("codex-bridge-windows-app.exe").path
      return WindowsProcessIdentity.pathsEqual(actual, app)
        || WindowsProcessIdentity.pathsEqual(actual, service)
    }
  }
#endif
