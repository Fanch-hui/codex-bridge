import Foundation

extension OutboundContentSecurity {
  /// Returns a closing Markdown or source delimiter when the path is inside a
  /// construct whose boundary is unambiguous. Ordinary prose uses a
  /// conservative whole-line replacement so a path containing spaces cannot
  /// leak its tail.
  package static func markdownPathEnd(
    in line: String,
    from start: String.Index
  ) -> String.Index? {
    var candidates: [String.Index] = []
    if let end = closingInlineCode(in: line, from: start) {
      candidates.append(end)
    }
    if let end = closingParenthesis(in: line, from: start),
      isMarkdownDestination(in: line, from: start)
    {
      candidates.append(end)
    }
    if let end = closingQuotedString(in: line, from: start) {
      candidates.append(end)
    }
    return candidates.min()
  }

  package static func redactUnsafeMarkdownPaths(
    in line: String,
    preservingSourceSyntax: Bool
  ) -> String {
    var result = ""
    var remainder = line
    while let start = unsafePathStart(
      in: remainder,
      preservingSourceSyntax: preservingSourceSyntax
    ) {
      result += String(remainder[..<start])
      guard let end = markdownPathEnd(in: remainder, from: start) else {
        return result + "[REDACTED]"
      }
      result += "[REDACTED]"
      remainder = String(remainder[end...])
    }
    return result + remainder
  }

  private static func closingInlineCode(
    in line: String,
    from start: String.Index
  ) -> String.Index? {
    var cursor = line.startIndex
    var opening: String.Index?
    while cursor < start {
      if line[cursor] == "`", !isEscaped(in: line, at: cursor) {
        opening = opening == nil ? cursor : nil
      }
      cursor = line.index(after: cursor)
    }
    guard opening != nil else { return nil }
    cursor = start
    while cursor < line.endIndex {
      if line[cursor] == "`", !isEscaped(in: line, at: cursor) {
        return cursor
      }
      cursor = line.index(after: cursor)
    }
    return nil
  }

  private static func isMarkdownDestination(
    in line: String,
    from start: String.Index
  ) -> Bool {
    guard start > line.startIndex else { return false }
    let before = line.index(before: start)
    if line[before] == "(" {
      guard before > line.startIndex else { return true }
      return line[line.index(before: before)] == "]"
    }
    guard line[before] == "<", before > line.startIndex else { return false }
    let opening = line.index(before: before)
    guard opening > line.startIndex else { return true }
    return line[line.index(before: opening)] == "]"
  }

  private static func closingParenthesis(
    in line: String,
    from start: String.Index
  ) -> String.Index? {
    var depth = 0
    var cursor = start
    while cursor < line.endIndex {
      let character = line[cursor]
      if character == "\\" {
        cursor = line.index(after: cursor)
        if cursor < line.endIndex {
          cursor = line.index(after: cursor)
        }
        continue
      }
      if character == "(" {
        depth += 1
      } else if character == ")" {
        if depth == 0 { return cursor }
        depth -= 1
      }
      cursor = line.index(after: cursor)
    }
    return nil
  }

  private static func closingQuotedString(
    in line: String,
    from start: String.Index
  ) -> String.Index? {
    guard start > line.startIndex else { return nil }
    var quote: Character?
    var cursor = line.startIndex
    while cursor < start {
      let character = line[cursor]
      if (character == "\"" || character == "'") && !isEscaped(in: line, at: cursor) {
        quote = quote == character ? nil : (quote ?? character)
      }
      cursor = line.index(after: cursor)
    }
    guard let quote else { return nil }
    cursor = start
    while cursor < line.endIndex {
      if line[cursor] == quote, !isEscaped(in: line, at: cursor) {
        return cursor
      }
      cursor = line.index(after: cursor)
    }
    return nil
  }

  private static func isEscaped(in line: String, at index: String.Index) -> Bool {
    var slashCount = 0
    var cursor = index
    while cursor > line.startIndex {
      cursor = line.index(before: cursor)
      guard line[cursor] == "\\" else { break }
      slashCount += 1
    }
    return slashCount % 2 == 1
  }
}
