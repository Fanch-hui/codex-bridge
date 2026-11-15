import BridgeProjects
import BridgeSecurity
import Foundation

struct ProjectFilePolicy: Sendable {
  private let sensitivePathPolicy = SensitivePathPolicy()
  private let forbiddenPatterns: [ForbiddenPathPattern]

  init(forbiddenPatterns: [ForbiddenPathPattern]) {
    self.forbiddenPatterns = forbiddenPatterns
  }

  func allows(_ path: SecureRelativePath) -> Bool {
    sensitivePathPolicy.allows(path)
      && !forbiddenPatterns.contains { GlobPathMatcher.matches(path.value, pattern: $0.value) }
  }
}

private enum GlobPathMatcher {
  static func matches(_ path: String, pattern: String) -> Bool {
    #if os(Windows)
      let normalizedPath = path.lowercased()
      let normalizedPattern = pattern.lowercased()
    #else
      let normalizedPath = path
      let normalizedPattern = pattern
    #endif
    let pathComponents = normalizedPath.split(separator: "/").map(String.init)
    let patternComponents = normalizedPattern.split(separator: "/").map(String.init)
    var previous = [Bool](repeating: false, count: pathComponents.count + 1)
    previous[0] = true

    for patternComponent in patternComponents {
      var current = [Bool](repeating: false, count: pathComponents.count + 1)
      if patternComponent == "**" {
        current[0] = previous[0]
        for index in pathComponents.indices {
          current[index + 1] = previous[index + 1] || current[index]
        }
      } else {
        for index in pathComponents.indices where previous[index] {
          current[index + 1] = componentMatches(
            pathComponents[index],
            pattern: patternComponent
          )
        }
      }
      previous = current
    }
    return previous[pathComponents.count]
  }

  private static func componentMatches(_ value: String, pattern: String) -> Bool {
    let valueCharacters = Array(value)
    let patternCharacters = Array(pattern)
    var previous = [Bool](repeating: false, count: valueCharacters.count + 1)
    previous[0] = true

    for patternCharacter in patternCharacters {
      var current = [Bool](repeating: false, count: valueCharacters.count + 1)
      if patternCharacter == "*" {
        current[0] = previous[0]
        for index in valueCharacters.indices {
          current[index + 1] = previous[index + 1] || current[index]
        }
      } else {
        for index in valueCharacters.indices where previous[index] {
          current[index + 1] = valueCharacters[index] == patternCharacter
        }
      }
      previous = current
    }
    return previous[valueCharacters.count]
  }
}

struct RedactedTextLine: Equatable, Sendable {
  let text: String
  let redacted: Bool
}

package enum ProjectSecretRedactor {
  static let replacement = "[REDACTED: suspected secret]"

  package static func containsSensitiveContent(_ text: String) -> Bool {
    var found = false
    text.enumerateLines { line, stop in
      if isSuspectedSecret(line) {
        found = true
        stop = true
      }
    }
    return found
  }

  static func redact(_ line: String) -> RedactedTextLine {
    guard isSuspectedSecret(line) else {
      return RedactedTextLine(text: line, redacted: false)
    }
    return RedactedTextLine(text: replacement, redacted: true)
  }

  private static func isSuspectedSecret(_ line: String) -> Bool {
    let lowercased = line.lowercased()
    if lowercased.contains("-----begin ") && lowercased.contains("private key-----") {
      return true
    }
    return containsCredentialAssignment(lowercased) || containsTokenPrefix(lowercased)
  }

  private static let credentialNames = [
    "api_key", "apikey", "access_token", "refresh_token", "client_secret",
    "password", "passwd", "secret_key", "runtime_key",
  ]

  private static func containsCredentialAssignment(_ line: String) -> Bool {
    credentialNames.contains { name in
      hasCredentialValue(after: "\(name)=", in: line, isTypedForm: false)
        || hasCredentialValue(after: "\(name):", in: line, isTypedForm: true)
    }
  }

  /// The value after `name=` / `name:` must look like a literal: an empty string is not one, and
  /// `name: Type = initializer` is a declaration whose value is only its quoted initializer.
  private static func hasCredentialValue(after marker: String, in line: String, isTypedForm: Bool)
    -> Bool
  {
    guard let range = line.range(of: marker) else { return false }
    let value = line[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
    guard value.count >= 8 else { return false }
    if let content = quotedContent(value) { return !content.isEmpty }
    guard isTypedForm else { return true }
    let declaredType = value.prefix { !$0.isWhitespace }
    let tail = value.dropFirst(declaredType.count).trimmingCharacters(in: .whitespacesAndNewlines)
    guard tail.hasPrefix("=") else { return true }
    let initializer = tail.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines)
    return quotedContent(initializer).map { !$0.isEmpty } ?? false
  }

  /// The text inside a leading quote (up to the closing quote), or nil when the value is unquoted.
  private static func quotedContent(_ value: String) -> String? {
    guard let quote = value.first, "\"'`".contains(quote) else { return nil }
    let body = value.dropFirst()
    return String(body.prefix { $0 != quote })
  }

  private static let tokenPrefixes = [
    "bearer ", "sk-", "ghp_", "gho_", "github_pat_", "xoxb-", "xoxp-",
  ]
  private static let minimumTokenLength = 12

  private static func containsTokenPrefix(_ line: String) -> Bool {
    tokenPrefixes.contains { hasToken(afterPrefix: $0, in: line) }
  }

  /// A prefix counts only at a word boundary and when a long run of token characters follows, so
  /// `risk-aware scheduling` (`sk-` inside a word) or `bearer of news` are not credentials.
  private static func hasToken(afterPrefix prefix: String, in line: String) -> Bool {
    let isBearer = prefix == "bearer "
    var searchStart = line.startIndex
    while let range = line.range(of: prefix, range: searchStart..<line.endIndex) {
      var tokenStart = range.upperBound
      if isBearer {
        while tokenStart < line.endIndex, line[tokenStart] == " " || line[tokenStart] == "\t" {
          tokenStart = line.index(after: tokenStart)
        }
      }
      if isWordBoundary(before: range.lowerBound, in: line),
        line[tokenStart...].prefix(while: { isTokenCharacter($0, allowsBearerSymbols: isBearer) })
          .count >= minimumTokenLength
      {
        return true
      }
      searchStart = line.index(after: range.lowerBound)
    }
    return false
  }

  private static func isWordBoundary(before index: String.Index, in line: String) -> Bool {
    guard index > line.startIndex else { return true }
    let previous = line[line.index(before: index)]
    return !(previous.isLetter || previous.isNumber)
  }

  private static func isTokenCharacter(_ character: Character, allowsBearerSymbols: Bool) -> Bool {
    guard character.isASCII else { return false }
    if character.isLetter || character.isNumber || character == "_" || character == "-" {
      return true
    }
    return allowsBearerSymbols && ".~+/=".contains(character)
  }
}
