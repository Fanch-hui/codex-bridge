#if os(macOS)
  import Darwin
  import Foundation
  import Security

  extension MacLocalMCPChannel {
    /// Verify the kernel-provided peer identity against the expected installation.
    public static func acceptsPeer(descriptor: Int32, expectedExecutableURL: URL) -> Bool {
      var uid: uid_t = 0
      var gid: gid_t = 0
      guard getpeereid(descriptor, &uid, &gid) == 0, uid == geteuid() else { return false }

      var audit = audit_token_t()
      var length = socklen_t(MemoryLayout<audit_token_t>.size)
      guard getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERTOKEN, &audit, &length) == 0,
        length == MemoryLayout<audit_token_t>.size
      else { return false }
      let token = withUnsafeBytes(of: &audit) { Data($0) }
      let attributes = [kSecGuestAttributeAudit: token as CFData] as CFDictionary
      var guest: SecCode?
      var staticGuest: SecStaticCode?
      var actual: CFURL?
      var expected: SecStaticCode?
      var expectedPath: CFURL?
      var requirement: SecRequirement?
      let executable = expectedExecutableURL.resolvingSymlinksInPath().standardizedFileURL
      guard executable.isFileURL,
        SecCodeCopyGuestWithAttributes(nil, attributes, [], &guest) == errSecSuccess,
        let guest,
        SecCodeCopyStaticCode(guest, [], &staticGuest) == errSecSuccess,
        let staticGuest,
        SecCodeCopyPath(staticGuest, [], &actual) == errSecSuccess,
        let actual,
        SecStaticCodeCreateWithPath(executable as CFURL, [], &expected) == errSecSuccess,
        let expected,
        SecCodeCopyPath(expected, [], &expectedPath) == errSecSuccess,
        let expectedPath,
        (actual as URL).resolvingSymlinksInPath().standardizedFileURL
          == (expectedPath as URL).resolvingSymlinksInPath().standardizedFileURL,
        SecCodeCopyDesignatedRequirement(expected, [], &requirement) == errSecSuccess,
        let requirement
      else { return false }
      return SecCodeCheckValidity(guest, [], requirement) == errSecSuccess
    }
  }
#endif
