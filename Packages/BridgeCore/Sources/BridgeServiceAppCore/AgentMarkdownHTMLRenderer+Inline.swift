import Foundation

extension AgentMarkdownHTMLRenderer {
  static func inlineHTML(_ source: String) -> String {
    let characters = Array(source)
    return renderInline(characters, from: 0, to: characters.count)
  }

  private struct InlineToken {
    let html: String
    let nextIndex: Int
  }

  private static func renderInline(
    _ characters: [Character],
    from start: Int,
    to end: Int
  ) -> String {
    var result = ""
    var index = start
    while index < end {
      if let token = token(at: index, in: characters, until: end) {
        result += token.html
        index = token.nextIndex
      } else {
        result += escapeText(String(characters[index]))
        index += 1
      }
    }
    return result
  }

  private static func token(
    at index: Int,
    in characters: [Character],
    until end: Int
  ) -> InlineToken? {
    escapedToken(at: index, in: characters, until: end)
      ?? codeToken(at: index, in: characters, until: end)
      ?? linkToken(at: index, in: characters, until: end)
      ?? strikeToken(at: index, in: characters, until: end)
      ?? emphasisToken(at: index, in: characters, until: end)
  }

  private static func escapedToken(
    at index: Int,
    in characters: [Character],
    until end: Int
  ) -> InlineToken? {
    guard characters[index] == "\\", index + 1 < end,
      isEscapable(characters[index + 1])
    else { return nil }
    return InlineToken(
      html: escapeText(String(characters[index + 1])),
      nextIndex: index + 2
    )
  }

  private static func codeToken(
    at index: Int,
    in characters: [Character],
    until end: Int
  ) -> InlineToken? {
    guard characters[index] == "`" else { return nil }
    let run = markerRunLength("`", at: index, in: characters, until: end)
    if let closing = closingMarker(
      "`", length: run, after: index + run, in: characters, until: end
    ) {
      let code = String(characters[(index + run)..<closing])
      return InlineToken(
        html: "<code class=\"markdown-inline-code\">\(escapeText(code))</code>",
        nextIndex: closing + run
      )
    }
    guard run == 1 else { return nil }
    let code = String(characters[(index + 1)..<end])
    return InlineToken(
      html: "<code class=\"markdown-inline-code\">\(escapeText(code))</code>",
      nextIndex: end
    )
  }

  private static func linkToken(
    at index: Int,
    in characters: [Character],
    until end: Int
  ) -> InlineToken? {
    let isImage = characters[index] == "!"
    let bracketIndex = isImage ? index + 1 : index
    guard characters[index] == "[" || (isImage && bracketIndex < end),
      let link = parseLink(in: characters, at: bracketIndex, until: end)
    else { return nil }
    guard safeWebURL(link.destination) else {
      if link.destination == "[REDACTED]" {
        let label = renderInline(
          characters,
          from: link.labelStart + 1,
          to: link.labelEnd
        )
        return InlineToken(html: label, nextIndex: link.end)
      }
      return InlineToken(
        html: escapeText(String(characters[index..<link.end])),
        nextIndex: link.end
      )
    }
    let label = renderInline(
      characters,
      from: link.labelStart + 1,
      to: link.labelEnd
    )
    let prefix = isImage ? "!" : ""
    let html =
      "<a href=\"\(escapeAttribute(link.destination))\" target=\"_blank\" rel=\"noopener noreferrer\">\(label)</a>"
    return InlineToken(html: prefix + html, nextIndex: link.end)
  }

  private static func strikeToken(
    at index: Int,
    in characters: [Character],
    until end: Int
  ) -> InlineToken? {
    guard characters[index] == "~", index + 1 < end, characters[index + 1] == "~",
      let closing = closingMarker("~", length: 2, after: index + 2, in: characters, until: end)
    else { return nil }
    let body = renderInline(characters, from: index + 2, to: closing)
    return InlineToken(html: "<del>\(body)</del>", nextIndex: closing + 2)
  }

  private static func emphasisToken(
    at index: Int,
    in characters: [Character],
    until end: Int
  ) -> InlineToken? {
    let marker = characters[index]
    guard marker == "*" || marker == "_" else { return nil }
    let run = markerRunLength(marker, at: index, in: characters, until: end)
    guard
      !(marker == "_"
        && isIntrawordUnderscore(
          at: index, run: run, in: characters, until: end
        ))
    else { return nil }
    if run >= 3,
      let closing = closingMarker(marker, length: 3, after: index + 3, in: characters, until: end)
    {
      let body = renderInline(characters, from: index + 3, to: closing)
      return InlineToken(
        html: "<strong><em>\(body)</em></strong>",
        nextIndex: closing + 3
      )
    }
    if run >= 2,
      let closing = closingMarker(marker, length: 2, after: index + 2, in: characters, until: end)
    {
      let body = renderInline(characters, from: index + 2, to: closing)
      return InlineToken(html: "<strong>\(body)</strong>", nextIndex: closing + 2)
    }
    guard
      let closing = closingMarker(marker, length: 1, after: index + 1, in: characters, until: end)
    else {
      return nil
    }
    let body = renderInline(characters, from: index + 1, to: closing)
    return InlineToken(html: "<em>\(body)</em>", nextIndex: closing + 1)
  }

  private struct Link {
    let labelStart: Int
    let labelEnd: Int
    let destination: String
    let end: Int
  }

  private static func parseLink(
    in characters: [Character],
    at index: Int,
    until end: Int
  ) -> Link? {
    guard index < end, characters[index] == "[" else { return nil }
    var labelDepth = 0
    var cursor = index + 1
    while cursor < end {
      if characters[cursor] == "\\" {
        cursor += min(2, end - cursor)
        continue
      }
      if characters[cursor] == "[" { labelDepth += 1 }
      if characters[cursor] == "]" {
        if labelDepth == 0 { break }
        labelDepth -= 1
      }
      cursor += 1
    }
    guard cursor < end, cursor + 1 < end, characters[cursor + 1] == "(" else { return nil }
    let labelEnd = cursor
    let destinationStart = labelEnd + 2
    cursor = destinationStart
    var parentheses = 0
    while cursor < end {
      if characters[cursor] == "\\" {
        cursor += min(2, end - cursor)
        continue
      }
      if characters[cursor] == "(" { parentheses += 1 }
      if characters[cursor] == ")" {
        if parentheses == 0 { break }
        parentheses -= 1
      }
      cursor += 1
    }
    guard cursor < end else { return nil }
    let rawDestination = String(characters[destinationStart..<cursor])
    let destination = linkDestination(rawDestination)
    return Link(
      labelStart: index,
      labelEnd: labelEnd,
      destination: destination,
      end: cursor + 1
    )
  }

  private static func linkDestination(_ value: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.first == "<",
      let closing = trimmed.lastIndex(of: ">"),
      closing > trimmed.startIndex
    else {
      return trimmed.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? trimmed
    }
    return String(trimmed[trimmed.index(after: trimmed.startIndex)..<closing])
  }

  private static func safeWebURL(_ value: String) -> Bool {
    guard let url = URL(string: value), let scheme = url.scheme?.lowercased() else {
      return false
    }
    return scheme == "http" || scheme == "https"
  }

  private static func isEscapable(_ character: Character) -> Bool {
    "\\*_~`#[]()|".contains(character)
  }

  private static func closingMarker(
    _ marker: Character,
    length: Int,
    after start: Int,
    in characters: [Character],
    until end: Int
  ) -> Int? {
    var index = start
    while index + length <= end {
      if characters[index] == "\\" {
        index += min(2, end - index)
        continue
      }
      let run = markerRunLength(marker, at: index, in: characters, until: end)
      if run >= length, run == length || length > 1 {
        return index
      }
      index += max(run, 1)
    }
    return nil
  }

  private static func markerRunLength(
    _ marker: Character,
    at index: Int,
    in characters: [Character],
    until end: Int
  ) -> Int {
    var cursor = index
    while cursor < end, characters[cursor] == marker { cursor += 1 }
    return cursor - index
  }

  private static func isIntrawordUnderscore(
    at index: Int,
    run: Int,
    in characters: [Character],
    until end: Int
  ) -> Bool {
    guard index > 0, index + run < end else { return false }
    return !characters[index - 1].isWhitespace && !characters[index + run].isWhitespace
  }
}
