import Foundation

extension OutboundContentSecurity {
  /// Keep credential labels from earlier chunks in scope when redacting a cursor page.
  public static func redactedCommandContinuation(
    context: String, delta: String, maximumUTF8Bytes: Int
  ) -> String {
    let combined = context + delta
    let source = combined as NSString
    let requested = NSRange(location: context.utf16.count, length: delta.utf16.count)
    var spans: [NSRange] = []
    let patterns =
      forbiddenPatterns + [
        #"(?is)-----BEGIN(?: [A-Z0-9]+)* PRIVATE KEY-----.*?(?:-----END(?: [A-Z0-9]+)* PRIVATE KEY-----|$)"#
      ]
    for pattern in patterns {
      guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
      for match in expression.matches(
        in: combined, range: NSRange(location: 0, length: source.length))
      {
        let overlap = NSIntersectionRange(match.range, requested)
        if overlap.length > 0 { spans.append(overlap) }
      }
    }
    var merged: [NSRange] = []
    for span in spans.sorted(by: { $0.location < $1.location }) {
      if let last = merged.last, NSMaxRange(last) >= span.location {
        merged[merged.count - 1] = NSUnionRange(last, span)
      } else {
        merged.append(span)
      }
    }
    let output = NSMutableString(string: delta)
    for span in merged.reversed() {
      output.replaceCharacters(
        in: NSRange(location: span.location - requested.location, length: span.length),
        with: "[REDACTED]")
    }
    return redactedCommandOutput(output as String, maximumUTF8Bytes: maximumUTF8Bytes)
  }
}
