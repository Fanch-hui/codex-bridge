import Foundation

public enum QoderDistribution: String, Codable, CaseIterable, Sendable {
  case cn
  case international

  public var displayName: String { self == .cn ? "Qoder CN" : "Qoder" }

  public var installationDisplayName: String {
    self == .cn ? "Qoder CN" : "Qoder International"
  }

  public static func identify(executablePath: String) -> Self? {
    let components = executablePath.replacingOccurrences(of: "\\", with: "/")
      .split(separator: "/").map { $0.lowercased() }
    if containsPackage(["node_modules", "@qodercn-ai", "qoderclicn"], in: components) {
      return .cn
    }
    if containsPackage(["node_modules", "@qoder-ai", "qodercli"], in: components) {
      return .international
    }
    let name = components.last ?? ""
    let stem = [".exe", ".cmd", ".bat", ".js", ".cjs"].reduce(name) { value, suffix in
      value.hasSuffix(suffix) ? String(value.dropLast(suffix.count)) : value
    }
    switch stem {
    case "qodercn", "qoderclicn", "qodercn-npm-dispatcher": return .cn
    case "qoder", "qodercli", "qoder-npm-dispatcher": return .international
    default: return nil
    }
  }

  public static func identify(displayName: String) -> Self? {
    switch displayName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "qoder cn": return .cn
    case "qoder international": return .international
    default: return nil
    }
  }

  private static func containsPackage(_ package: [String], in components: [String]) -> Bool {
    guard components.count >= package.count else { return false }
    return (0...(components.count - package.count)).contains { start in
      Array(components[start..<(start + package.count)]) == package
    }
  }
}
