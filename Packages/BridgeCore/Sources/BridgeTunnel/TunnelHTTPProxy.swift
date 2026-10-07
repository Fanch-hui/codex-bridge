import Foundation

public struct TunnelHTTPProxy: Equatable, Sendable {
  public let url: URL

  public init(validating value: String) throws {
    guard !value.utf8.contains(where: { $0 <= 0x20 || $0 == 0x7F }),
      let components = URLComponents(string: value),
      let scheme = components.scheme?.lowercased(),
      scheme == "http" || scheme == "https",
      let host = components.host, !host.isEmpty,
      components.port.map({ (1...65_535).contains($0) }) ?? true,
      components.user == nil, components.password == nil,
      components.path.isEmpty || components.path == "/",
      components.query == nil, components.fragment == nil,
      let url = components.url
    else {
      throw TunnelConfigurationError.invalidHTTPProxy
    }
    self.url = url
  }

  public static func parse(_ value: String?) throws -> TunnelHTTPProxy? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : try TunnelHTTPProxy(validating: trimmed)
  }
}
