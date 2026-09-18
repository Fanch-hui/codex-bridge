#if os(Windows)
  import Foundation
  import WinSDK

  extension WindowsAppContainerProcess {
    private typealias DeleteAppContainerProfileFn =
      @convention(c) (
        UnsafePointer<WCHAR>?
      ) -> HRESULT

    static func cleanupProfile(
      name: String,
      accessPath: String? = nil,
      sid: PSID? = nil
    ) {
      if let accessPath, let sid {
        _ = revokeAccess(from: accessPath, for: sid)
      }
      defer {
        if let sid { _ = FreeSid(sid) }
      }
      guard let userenv = "userenv.dll".withCString(encodedAs: UTF16.self, { LoadLibraryW($0) })
      else { return }
      defer { _ = FreeLibrary(userenv) }
      guard
        let deleteProfilePtr = "DeleteAppContainerProfile".withCString({
          GetProcAddress(userenv, $0)
        })
      else { return }
      let deleteProfile = unsafeBitCast(deleteProfilePtr, to: DeleteAppContainerProfileFn.self)
      _ = name.withCString(encodedAs: UTF16.self) { deleteProfile($0) }
    }

    static func grantAccess(to path: String, for sid: PSID) -> Bool {
      updateAccess(
        at: path,
        for: sid,
        mode: GRANT_ACCESS,
        permissions: DWORD(0x1000_0000),
        inheritance: DWORD(1 | 2)
      )
    }

    private static func revokeAccess(from path: String, for sid: PSID) -> Bool {
      updateAccess(
        at: path,
        for: sid,
        mode: REVOKE_ACCESS,
        permissions: 0,
        inheritance: 0
      )
    }

    private static func updateAccess(
      at path: String,
      for sid: PSID,
      mode: ACCESS_MODE,
      permissions: DWORD,
      inheritance: DWORD
    ) -> Bool {
      var entry = EXPLICIT_ACCESS_W()
      entry.grfAccessPermissions = permissions
      entry.grfAccessMode = mode
      entry.grfInheritance = inheritance
      entry.Trustee.TrusteeForm = TRUSTEE_IS_SID
      entry.Trustee.TrusteeType = TRUSTEE_IS_UNKNOWN
      entry.Trustee.ptstrName = UnsafeMutablePointer<WCHAR>(OpaquePointer(sid))

      var oldDacl: PACL?
      var securityDescriptor: PSECURITY_DESCRIPTOR?
      let getResult = path.withCString(encodedAs: UTF16.self) { pointer in
        GetNamedSecurityInfoW(
          UnsafeMutablePointer(mutating: pointer),
          SE_FILE_OBJECT,
          DWORD(DACL_SECURITY_INFORMATION),
          nil,
          nil,
          &oldDacl,
          nil,
          &securityDescriptor
        )
      }
      guard getResult == ERROR_SUCCESS else { return false }
      defer {
        if let securityDescriptor { _ = LocalFree(securityDescriptor) }
      }

      var newDacl: PACL?
      let setResult = SetEntriesInAclW(1, &entry, oldDacl, &newDacl)
      guard setResult == ERROR_SUCCESS, let newDacl else { return false }
      defer { _ = LocalFree(newDacl) }

      let applyResult = path.withCString(encodedAs: UTF16.self) { pointer in
        SetNamedSecurityInfoW(
          UnsafeMutablePointer(mutating: pointer),
          SE_FILE_OBJECT,
          DWORD(DACL_SECURITY_INFORMATION),
          nil,
          nil,
          newDacl,
          nil
        )
      }
      return applyResult == ERROR_SUCCESS
    }
  }
#endif
