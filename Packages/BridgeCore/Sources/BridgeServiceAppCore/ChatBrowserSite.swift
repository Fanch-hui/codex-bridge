import Foundation

public enum ChatBrowserSite: String, Codable, CaseIterable, Sendable {
  case chatGPT = "chatgpt"
  case gemini

  public var displayName: String {
    switch self {
    case .chatGPT: "ChatGPT"
    case .gemini: "Gemini"
    }
  }

  public var homeURL: URL {
    switch self {
    case .chatGPT: URL(string: "https://chatgpt.com")!
    case .gemini: URL(string: "https://gemini.google.com")!
    }
  }

  public func validatedURL(_ url: URL?) -> URL? {
    guard let url, url.scheme?.lowercased() == "https",
      let host = url.host?.lowercased(), url.user == nil, url.password == nil,
      url.port == nil || url.port == 443
    else { return nil }
    let allowed: Bool
    switch self {
    case .chatGPT:
      allowed = host == "chatgpt.com" || host.hasSuffix(".chatgpt.com")
    case .gemini:
      allowed = host == "gemini.google.com"
    }
    return allowed ? url : nil
  }
}

public struct ChatBrowserPreferences {
  private let defaults: UserDefaults
  private static let selectedSiteKey = "chatBrowserSite"
  private static let enabledKey = "chatBrowserEnabled"

  public init(defaults: UserDefaults) {
    self.defaults = defaults
  }

  public var isEnabled: Bool {
    get { defaults.object(forKey: Self.enabledKey) as? Bool ?? false }
    nonmutating set { defaults.set(newValue, forKey: Self.enabledKey) }
  }

  public var selectedSite: ChatBrowserSite {
    get {
      defaults.string(forKey: Self.selectedSiteKey)
        .flatMap(ChatBrowserSite.init(rawValue:)) ?? .chatGPT
    }
    nonmutating set {
      defaults.set(newValue.rawValue, forKey: Self.selectedSiteKey)
    }
  }

  public func resumeURL(for site: ChatBrowserSite) -> URL {
    let stored = defaults.string(forKey: resumeKey(for: site)).flatMap(URL.init(string:))
    return site.validatedURL(stored) ?? site.homeURL
  }

  public func remember(_ url: URL, for site: ChatBrowserSite) {
    guard let safeURL = site.validatedURL(url) else { return }
    defaults.set(safeURL.absoluteString, forKey: resumeKey(for: site))
  }

  private func resumeKey(for site: ChatBrowserSite) -> String {
    switch site {
    case .chatGPT: "chatBrowserResumeURL"
    case .gemini: "chatBrowserResumeURL.gemini"
    }
  }
}
