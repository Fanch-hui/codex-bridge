#if os(Windows)
  import Foundation
  import WinSDK

  extension WindowsAppContainerProcess {
    static func windowsEnvironmentBlock(_ environment: [String: String]) -> String {
      var values: [String: String] = [:]
      for (name, value) in environment {
        if let existing = values.keys.first(where: {
          windowsEnvironmentNameCompare($0, name) == 2
        }) {
          values.removeValue(forKey: existing)
        }
        values[name] = value
      }
      let entries = values.sorted {
        windowsEnvironmentNameCompare($0.key, $1.key) == 1
      }.map { "\($0.key)=\($0.value)" }
      return entries.joined(separator: "\0") + "\0\0"
    }
    private static func windowsEnvironmentNameCompare(_ lhs: String, _ rhs: String) -> CInt {
      lhs.withCString(encodedAs: UTF16.self) { left in
        rhs.withCString(encodedAs: UTF16.self) { right in
          CompareStringOrdinal(left, -1, right, -1, true)
        }
      }
    }
  }
#endif
