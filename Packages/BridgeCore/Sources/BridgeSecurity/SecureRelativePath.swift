import Foundation

public struct SecureRelativePath: Codable, Hashable, Sendable {
  public let value: String
  public let components: [String]

  public init(_ input: String) throws {
    guard !input.isEmpty else {
      throw PathSecurityError.invalidRelativePath("empty path")
    }
    guard !input.contains("\0") else {
      throw PathSecurityError.invalidRelativePath("NUL byte")
    }
    #if os(Windows)
      guard input.rangeOfCharacter(from: .controlCharacters) == nil else {
        throw PathSecurityError.invalidRelativePath("control character")
      }

      // Project paths use one portable separator on Windows. Parsing both
      // separators prevents a native path from becoming one opaque component.
      let normalized = input.replacingOccurrences(of: "\\", with: "/")
    #else
      let normalized = input
    #endif
    guard !normalized.hasPrefix("/") && !normalized.hasPrefix("~") else {
      throw PathSecurityError.invalidRelativePath("absolute or home-relative path")
    }
    guard !normalized.lowercased().hasPrefix("file:") else {
      throw PathSecurityError.invalidRelativePath("file URL")
    }

    let parts = normalized.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    #if os(Windows)
      guard parts.allSatisfy(Self.isWindowsSafeComponent) else {
        throw PathSecurityError.invalidRelativePath("invalid Windows path component")
      }
    #else
      guard parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
        throw PathSecurityError.invalidRelativePath("empty, dot, or parent component")
      }
    #endif

    components = parts
    value = parts.joined(separator: "/")
  }

  #if os(Windows)
    private static func isWindowsSafeComponent(_ component: String) -> Bool {
      guard !component.isEmpty, component != ".", component != ".." else { return false }
      guard !component.contains(":") else { return false }
      guard !component.contains("*") && !component.contains("?") else { return false }
      guard component.last != " " && component.last != "." else { return false }

      let basename =
        component.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false).first
        .map(String.init)?.lowercased() ?? ""
      let reservedNames: Set<String> = [
        "con", "prn", "aux", "nul",
        "com1", "com2", "com3", "com4", "com5", "com6", "com7", "com8", "com9",
        "lpt1", "lpt2", "lpt3", "lpt4", "lpt5", "lpt6", "lpt7", "lpt8", "lpt9",
      ]
      return !reservedNames.contains(basename)
    }
  #endif
}
