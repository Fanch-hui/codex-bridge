import BridgeAgentCore
import Foundation

public struct OutboundRedaction: Equatable, Sendable {
  public let text: String
  public let redactedLineCount: Int
  public let truncated: Bool

  public var changed: Bool {
    redactedLineCount > 0 || truncated
  }
}

public enum OutboundContentSecurity {
  private enum PathRedactionMode {
    case none
    case remainderOfLine
    case commandOutput
  }

  static let forbiddenPatterns = [
    #"(?i)-----BEGIN(?: [A-Z0-9]+)* PRIVATE KEY-----"#,
    #"(?i)\bBearer\s+[^\s,;]+"#,
    #"(?i)\b(?:sk-[A-Za-z0-9_-]{16,}|gh[pousr]_[A-Za-z0-9_]{16,}|github_pat_[A-Za-z0-9_]{16,})\b"#,
    #"(?i)["']?(?:authorization|cookie|client[_-]?secret|api[_-]?key|runtime[_-]?key|access[_-]?token|refresh[_-]?token|password|passwd|secret(?:[_-]?key)?)["']?\s*[:=]\s*(?:"[^"\r\n]+"|'[^'\r\n]+'|[A-Za-z0-9_./+=:@-]+(?=$|[\s,;]))"#,
    #"(?i)"?x-codex-bridge-token"?\s*[:=]\s*"[^"\r\n]*""#,
    #"(?i)\bx-codex-bridge-token\b(?:\s*[:=]\s*[^\s,;]+)?"#,
    #"(?i)\bx-codex-(?:token|auth|mcp-auth|runtime-key)\b(?:\s*[:=]\s*[^\s,;]+)?"#,
    #"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b"#,
  ]

  private static let safeHTTPPattern = try! NSRegularExpression(
    pattern:
      #"(?i)(^|[\s\(\[\{<"'=,;])https?://(?:localhost|[A-Za-z0-9](?:[A-Za-z0-9.-]{0,251}[A-Za-z0-9])?)(?::[0-9]{1,5})?(?:[/\?#][^\s\)\]\}>"']*)?"#
  )
  private static let regularExpressionLiteralPattern = try! NSRegularExpression(
    pattern:
      #"(?x)(?:^|[\s=\(\[,!:?;{}])/(?:\\.|[^/\\\r\n])+/[dgimsuvy]+|(?:^|[\s=\(\[,!:?;{}])/(?:\\.|[^/\\\r\n])+/(?=\.(?:test|exec|match|replace)\s*\()"#
  )

  public static func isSafe(_ value: String) -> Bool {
    guard !containsUnsafePath(value) else { return false }
    return !forbiddenPatterns.contains { pattern in
      value.range(of: pattern, options: .regularExpression) != nil
    }
  }

  /// Checks only the secret patterns (keys, tokens, credentials) without the
  /// local-path heuristic. Used for structured payloads like patch text whose
  /// markers (`*** Add File: x`) legitimately contain `file:`-like text.
  public static func isSafeSecrets(_ value: String) -> Bool {
    !forbiddenPatterns.contains { pattern in
      value.range(of: pattern, options: .regularExpression) != nil
    }
  }

  public static func isSafeRelativePath(
    _ value: String,
    maximumUTF8Bytes: Int = 1_024
  ) -> Bool {
    #if os(Windows)
      guard maximumUTF8Bytes > 0, value.utf8.count <= maximumUTF8Bytes,
        value.rangeOfCharacter(from: .controlCharacters) == nil
      else { return false }
      return AgentPathSemantics.relativeComponents(value, style: .windows) != nil
        && !value.hasPrefix("~")
    #else
      guard maximumUTF8Bytes > 0, value.utf8.count <= maximumUTF8Bytes,
        !value.contains("\\"),
        value.rangeOfCharacter(from: .controlCharacters) == nil
      else { return false }
      return (try? SecureRelativePath(value)) != nil
    #endif
  }

  public static func isSafeOutboundRelativePath(
    _ value: String,
    maximumUTF8Bytes: Int = 1_024
  ) -> Bool {
    isSafeRelativePath(value, maximumUTF8Bytes: maximumUTF8Bytes) && isSafe(value)
  }

  public static func redacted(_ value: String, maximumUTF8Bytes: Int) -> String {
    redaction(of: value, maximumUTF8Bytes: maximumUTF8Bytes).text
  }

  /// Redacts credential-shaped values while preserving ordinary source paths.
  /// Skill documents are user-authored code and may legitimately contain paths.
  public static func redactedSecrets(_ value: String, maximumUTF8Bytes: Int) -> String {
    redaction(
      of: value,
      maximumUTF8Bytes: maximumUTF8Bytes,
      preservingSourceSyntax: true,
      pathMode: .none
    ).text
  }

  public static func redaction(
    of value: String,
    maximumUTF8Bytes: Int,
    preservingSourceSyntax: Bool = false
  ) -> OutboundRedaction {
    redaction(
      of: value,
      maximumUTF8Bytes: maximumUTF8Bytes,
      preservingSourceSyntax: preservingSourceSyntax,
      pathMode: .remainderOfLine
    )
  }

  public static func redactedCommandOutput(
    _ value: String,
    maximumUTF8Bytes: Int
  ) -> String {
    let normalized = stripTerminalControlSequences(value)
    return redaction(
      of: normalized,
      maximumUTF8Bytes: maximumUTF8Bytes,
      preservingSourceSyntax: false,
      pathMode: .commandOutput
    ).text
  }

  /// Sanitizes a command for a local task/approval display. Command paths are
  /// useful context in this surface, so only credential-shaped values are
  /// removed; the normal outbound text path still redacts local paths.
  public static func redactedCommand(
    _ value: String,
    maximumUTF8Bytes: Int
  ) -> String {
    redaction(
      of: value,
      maximumUTF8Bytes: maximumUTF8Bytes,
      preservingSourceSyntax: false,
      pathMode: .none
    ).text
  }

  /// Redacts command arguments while preserving their option/value structure.
  /// Values following credential-shaped options are sensitive even when they
  /// do not contain a recognizable key prefix or `key=value` spelling.
  public static func redactedCommandArguments(
    _ arguments: [String],
    maximumArguments: Int = 128,
    maximumArgumentUTF8Bytes: Int = 4 * 1_024
  ) -> [String] {
    guard maximumArguments > 0, maximumArgumentUTF8Bytes > 0 else { return [] }
    var result: [String] = []
    result.reserveCapacity(min(arguments.count, maximumArguments))
    var redactNextValue = false
    for argument in arguments.prefix(maximumArguments) {
      if redactNextValue {
        result.append("[REDACTED]")
        redactNextValue = false
        continue
      }
      let redacted = redactedCommand(argument, maximumUTF8Bytes: maximumArgumentUTF8Bytes)
      guard let equal = argument.firstIndex(of: "=") else {
        result.append(redacted)
        redactNextValue = isSensitiveCommandOption(argument)
        continue
      }
      let option = String(argument[..<equal])
      guard isSensitiveCommandOption(option) else {
        result.append(redacted)
        continue
      }
      result.append(
        redactedCommand(
          option + "=[REDACTED]",
          maximumUTF8Bytes: maximumArgumentUTF8Bytes
        )
      )
    }
    return result
  }

  private static func isSensitiveCommandOption(_ value: String) -> Bool {
    let option = value.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
      .lowercased()
      .replacingOccurrences(of: "_", with: "-")
    guard !option.isEmpty else { return false }
    let sensitiveTokens = [
      "token", "api-key", "runtime-key", "access-key", "access-token", "refresh-token",
      "secret", "password", "passwd", "authorization", "cookie", "credential", "auth",
      "client-secret", "mcp-auth",
    ]
    return sensitiveTokens.contains { token in
      option == token || option.hasSuffix("-\(token)")
    }
  }

  private static func redaction(
    of value: String,
    maximumUTF8Bytes: Int,
    preservingSourceSyntax: Bool,
    pathMode: PathRedactionMode
  ) -> OutboundRedaction {
    precondition(maximumUTF8Bytes > 0)
    var insidePrivateKey = false
    var redactedLineCount = 0
    let redacted = value.split(separator: "\n", omittingEmptySubsequences: false).map { part in
      let line = String(part)
      let privateKeyLine = redactPrivateKeyLine(line, insideBlock: &insidePrivateKey)
      let secretsRedacted = forbiddenPatterns.reduce(privateKeyLine) { result, pattern in
        result.replacingOccurrences(
          of: pattern,
          with: "[REDACTED]",
          options: .regularExpression
        )
      }
      let pathRedacted =
        switch pathMode {
        case .none:
          secretsRedacted
        case .remainderOfLine:
          redactUnsafePath(in: secretsRedacted, preservingSourceSyntax: preservingSourceSyntax)
        case .commandOutput:
          redactCommandOutputPaths(in: secretsRedacted)
        }
      if pathRedacted != line {
        redactedLineCount += 1
      }
      return pathRedacted
    }.joined(separator: "\n")
    guard redacted.utf8.count > maximumUTF8Bytes else {
      return OutboundRedaction(
        text: redacted,
        redactedLineCount: redactedLineCount,
        truncated: false
      )
    }
    let suffix = "…"
    let includesSuffix = maximumUTF8Bytes > suffix.utf8.count
    let prefixLimit = includesSuffix ? maximumUTF8Bytes - suffix.utf8.count : maximumUTF8Bytes
    var prefix = ""
    for character in redacted {
      guard prefix.utf8.count + character.utf8.count <= prefixLimit else { break }
      prefix.append(character)
    }
    return OutboundRedaction(
      text: includesSuffix ? prefix + suffix : prefix,
      redactedLineCount: redactedLineCount,
      truncated: true
    )
  }

  private static func stripTerminalControlSequences(_ value: String) -> String {
    let scalars = Array(value.unicodeScalars)
    var result: [UnicodeScalar] = []
    result.reserveCapacity(scalars.count)
    var index = 0
    while index < scalars.count {
      let scalar = scalars[index].value
      if scalar == 0x1B {
        index += 1
        guard index < scalars.count else { break }
        switch scalars[index].value {
        case 0x5B:
          index += 1
          while index < scalars.count {
            let value = scalars[index].value
            index += 1
            if (0x40...0x7E).contains(value) { break }
          }
        case 0x5D:
          index += 1
          while index < scalars.count {
            let value = scalars[index].value
            if value == 0x07 {
              index += 1
              break
            }
            if value == 0x1B, index + 1 < scalars.count,
              scalars[index + 1].value == 0x5C
            {
              index += 2
              break
            }
            index += 1
          }
        default:
          index += 1
        }
        continue
      }
      if scalar < 0x20 && scalar != 0x09 && scalar != 0x0A && scalar != 0x0D
        || (0x7F...0x9F).contains(scalar)
      {
        index += 1
        continue
      }
      result.append(scalars[index])
      index += 1
    }
    return String(String.UnicodeScalarView(result))
  }

  private static func containsUnsafePath(_ value: String) -> Bool {
    value.split(separator: "\n", omittingEmptySubsequences: false).contains { line in
      unsafePathStart(in: String(line), preservingSourceSyntax: false) != nil
    }
  }

  private static func redactUnsafePath(
    in line: String,
    preservingSourceSyntax: Bool
  ) -> String {
    return Self.redactUnsafeMarkdownPaths(
      in: line,
      preservingSourceSyntax: preservingSourceSyntax
    )
  }

  private static func redactCommandOutputPaths(in line: String) -> String {
    var result = line
    while let start = unsafeAbsolutePathStart(in: result) {
      let end = commandOutputPathEnd(in: result, from: start)
      result.replaceSubrange(start..<end, with: "[REDACTED_PATH]")
    }
    return result
  }

  private static func unsafeAbsolutePathStart(in line: String) -> String.Index? {
    if let home = line.range(of: "~/")?.lowerBound { return home }
    let safeRanges = safeRanges(in: line, preservingSourceSyntax: false)
    #if os(Windows)
      if let windowsPath = windowsUnsafeAbsolutePathStart(in: line, safeRanges: safeRanges) {
        return windowsPath
      }
    #endif
    var safeRangeIndex = 0
    var index = line.startIndex
    while index < line.endIndex {
      defer { index = line.index(after: index) }
      while safeRangeIndex < safeRanges.count, index >= safeRanges[safeRangeIndex].upperBound {
        safeRangeIndex += 1
      }
      let isSafeURL =
        safeRangeIndex < safeRanges.count && safeRanges[safeRangeIndex].contains(index)
      guard line[index] == "/", !isSafeURL else { continue }
      let next = line.index(after: index)
      if next < line.endIndex, line[next].isWhitespace { continue }
      guard index == line.startIndex || !isRelativePathPrefix(line[line.index(before: index)])
      else { continue }
      return index
    }
    return nil
  }

  private static func commandOutputPathEnd(
    in line: String,
    from start: String.Index
  ) -> String.Index {
    if start > line.startIndex {
      let quote = line[line.index(before: start)]
      if quote == "\"" || quote == "'",
        let endQuote = line[start...].firstIndex(of: quote)
      {
        return endQuote
      }
    }
    var index = start
    while index < line.endIndex {
      let character = line[index]
      if character == ":" {
        let next = line.index(after: index)
        if next < line.endIndex, line[next].isNumber { return index }
      }
      if character == "," || character == ";" {
        let next = line.index(after: index)
        if next == line.endIndex || line[next].isWhitespace { return index }
      }
      if character == ")" || character == "]" {
        let next = line.index(after: index)
        if next == line.endIndex || line[next].isWhitespace { return index }
      }
      if character.isWhitespace {
        let next = line[index...].firstIndex { !$0.isWhitespace } ?? line.endIndex
        if isCommandOutputBoundary(line[next...]) { return index }
      }
      index = line.index(after: index)
    }
    return line.endIndex
  }

  private static func isCommandOutputBoundary(_ suffix: Substring) -> Bool {
    guard !suffix.isEmpty else { return true }
    if suffix.hasPrefix("/") || suffix.hasPrefix("~/") || suffix.hasPrefix("-") { return true }
    #if os(Windows)
      if windowsStartsWithAbsolutePath(suffix) { return true }
    #endif
    let lowercased = suffix.lowercased()
    return lowercased.hasPrefix("(pid")
      || lowercased.hasPrefix("[pid")
      || lowercased.hasPrefix("pid=")
      || lowercased.hasPrefix("exit=")
      || lowercased.hasPrefix("status=")
      || lowercased.hasPrefix("assertion ")
      || lowercased.hasPrefix("error:")
      || lowercased.hasPrefix("warning:")
  }

  package static func unsafePathStart(
    in line: String,
    preservingSourceSyntax: Bool
  ) -> String.Index? {
    var earliest = line.range(of: #"(?i)\bfile\s*:"#, options: .regularExpression)?.lowerBound
    if let home = line.range(of: "~/")?.lowerBound {
      earliest = earlier(earliest, home)
    }
    let safeRanges = safeRanges(in: line, preservingSourceSyntax: preservingSourceSyntax)
    #if os(Windows)
      if let windowsPath = windowsUnsafeAbsolutePathStart(in: line, safeRanges: safeRanges) {
        earliest = earlier(earliest, windowsPath)
      }
    #endif
    var safeRangeIndex = 0
    var index = line.startIndex
    while index < line.endIndex {
      defer { index = line.index(after: index) }
      while safeRangeIndex < safeRanges.count,
        index >= safeRanges[safeRangeIndex].upperBound
      {
        safeRangeIndex += 1
      }
      let isInsideSafeHTTPRange =
        safeRangeIndex < safeRanges.count && safeRanges[safeRangeIndex].contains(index)
      guard line[index] == "/", !isInsideSafeHTTPRange else { continue }
      let next = line.index(after: index)
      if next < line.endIndex, line[next] == "/" {
        earliest = earlier(earliest, index)
        continue
      }
      if next < line.endIndex, line[next].isWhitespace {
        continue
      }
      guard index == line.startIndex || !isRelativePathPrefix(line[line.index(before: index)])
      else { continue }
      earliest = earlier(earliest, index)
    }
    return earliest
  }

  private static func safeRanges(
    in line: String,
    preservingSourceSyntax: Bool
  ) -> [Range<String.Index>] {
    let fullRange = NSRange(line.startIndex..<line.endIndex, in: line)
    var ranges = safeHTTPPattern.matches(in: line, range: fullRange).compactMap { match in
      Range(match.range, in: line)
    }
    if preservingSourceSyntax {
      let strings = stringLiteralRanges(in: line)
      ranges.append(contentsOf: sourceDelimiterRanges(in: line, outside: strings))
      ranges.append(
        contentsOf: rangesOutsideStrings(
          regularExpressionLiteralPattern.matches(in: line, range: fullRange),
          in: line,
          strings: strings
        )
      )
    }
    return
      ranges
      .sorted { $0.lowerBound < $1.lowerBound }
  }

  private static func stringLiteralRanges(in line: String) -> [Range<String.Index>] {
    var ranges: [Range<String.Index>] = []
    var start: String.Index?
    var quote: Character?
    var escaped = false
    var index = line.startIndex
    while index < line.endIndex {
      let character = line[index]
      if let activeQuote = quote {
        if escaped {
          escaped = false
        } else if character == "\\" {
          escaped = true
        } else if character == activeQuote {
          let end = line.index(after: index)
          ranges.append((start ?? index)..<end)
          start = nil
          quote = nil
        }
      } else if character == "\"" || character == "'" {
        start = index
        quote = character
      }
      index = line.index(after: index)
    }
    if let start {
      ranges.append(start..<line.endIndex)
    }
    return ranges
  }

  private static func sourceDelimiterRanges(
    in line: String,
    outside strings: [Range<String.Index>]
  ) -> [Range<String.Index>] {
    var ranges: [Range<String.Index>] = []
    var stringIndex = 0
    var index = line.startIndex
    while index < line.endIndex {
      defer { index = line.index(after: index) }
      while stringIndex < strings.count, index >= strings[stringIndex].upperBound {
        stringIndex += 1
      }
      let insideString = stringIndex < strings.count && strings[stringIndex].contains(index)
      guard line[index] == "/", !insideString else { continue }
      if index > line.startIndex, line[line.index(before: index)] == "*" {
        ranges.append(index..<line.index(after: index))
        continue
      }
      let next = line.index(after: index)
      guard next < line.endIndex else { continue }
      if line[next] == "/", isRecognizedLineComment(in: line, after: next) {
        ranges.append(index..<line.index(after: next))
      } else if line[next] == "*", isSpacedDelimiter(in: line, after: next) {
        ranges.append(index..<line.index(after: index))
      }
    }
    return ranges
  }

  private static func rangesOutsideStrings(
    _ matches: [NSTextCheckingResult],
    in line: String,
    strings: [Range<String.Index>]
  ) -> [Range<String.Index>] {
    var ranges: [Range<String.Index>] = []
    var stringIndex = 0
    for match in matches {
      guard let range = Range(match.range, in: line),
        let slash = line[range].firstIndex(of: "/")
      else { continue }
      while stringIndex < strings.count, slash >= strings[stringIndex].upperBound {
        stringIndex += 1
      }
      let insideString = stringIndex < strings.count && strings[stringIndex].contains(slash)
      if !insideString {
        ranges.append(range)
      }
    }
    return ranges
  }

  private static func isRecognizedLineComment(
    in line: String,
    after secondSlash: String.Index
  ) -> Bool {
    let content = line.index(after: secondSlash)
    guard content < line.endIndex else { return true }
    if line[content].isWhitespace { return true }
    if line[content] == "/" {
      let afterDocMarker = line.index(after: content)
      return afterDocMarker == line.endIndex || line[afterDocMarker].isWhitespace
    }
    let suffix = line[content...].uppercased()
    return suffix.hasPrefix("TODO:") || suffix.hasPrefix("FIXME:") || suffix.hasPrefix("MARK:")
  }

  private static func isSpacedDelimiter(
    in line: String,
    after markerEnd: String.Index
  ) -> Bool {
    let content = line.index(after: markerEnd)
    return content == line.endIndex || line[content].isWhitespace
  }

  private static func redactPrivateKeyLine(
    _ line: String,
    insideBlock: inout Bool
  ) -> String {
    let uppercased = line.uppercased()
    let begins =
      uppercased.range(
        of: #"-----BEGIN(?: [A-Z0-9]+)* PRIVATE KEY-----"#,
        options: .regularExpression
      ) != nil
    let ends =
      uppercased.range(
        of: #"-----END(?: [A-Z0-9]+)* PRIVATE KEY-----"#,
        options: .regularExpression
      ) != nil
    guard begins || insideBlock else { return line }
    insideBlock = !ends
    return "[REDACTED]"
  }

  private static func earlier(
    _ current: String.Index?,
    _ candidate: String.Index
  ) -> String.Index {
    guard let current else { return candidate }
    return min(current, candidate)
  }

  private static func isRelativePathPrefix(_ character: Character) -> Bool {
    // A slash preceded by an alphanumeric character (any script, including
    // CJK) is part of prose like "原创帖/回复" rather than an absolute path;
    // only slash preceded by whitespace/line start or punctuation may begin a
    // local path such as "/Users/me".
    if character.isLetter || character.isNumber {
      return true
    }
    return "._~/-".contains(character)
  }
}
