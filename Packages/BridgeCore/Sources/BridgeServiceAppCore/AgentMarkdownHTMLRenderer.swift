import Foundation

public enum AgentMarkdownHTMLRenderer {
  public static func render(_ content: String, isFinal: Bool = true) -> String {
    guard isFinal else { return renderStreamingFallback(content) }
    if let cached = cache.value(for: content) { return cached }
    let rendered = AgentMarkdownDocument(content).blocks.map(renderBlock).joined()
    cache.insert(rendered, for: content)
    return rendered
  }

  private static let cache = AgentMarkdownHTMLCache()

  private static func renderStreamingFallback(_ content: String) -> String {
    let plainText = AgentMarkdownFallback.safePlainTextFallback(from: content)
    let cursor = #"<span class="markdown-cursor" aria-hidden="true">▍</span>"#
    let escapedText = escapeText(plainText)
    guard !escapedText.isEmpty else { return cursor }
    return "<p>\(escapedText)\(cursor)</p>"
  }

  private static func renderBlock(_ block: AgentMarkdownBlock) -> String {
    switch block.content {
    case .paragraph(let text):
      return "<p>\(inlineHTML(text))</p>"
    case .heading(let level, let text):
      let tag = "h\(min(max(level, 1) + 2, 6))"
      return "<\(tag)>\(inlineHTML(text))</\(tag)>"
    case .unorderedList(let items):
      return renderList(items, ordered: false)
    case .orderedList(let items):
      return renderList(items, ordered: true)
    case .quote(let text):
      return "<blockquote>\(inlineHTML(text))</blockquote>"
    case .code(let language, let text):
      return renderCode(language: language, text: text)
    case .table(let headers, let rows, let alignments):
      return renderTable(headers: headers, rows: rows, alignments: alignments)
    case .thematicBreak:
      return "<hr>"
    }
  }

  private static func renderList(_ items: [String], ordered: Bool) -> String {
    let tag = ordered ? "ol" : "ul"
    let body = items.map { "<li>\(inlineHTML($0))</li>" }.joined()
    return "<\(tag)>\(body)</\(tag)>"
  }

  private static func renderCode(language: String?, text: String) -> String {
    let languageClass =
      language.map {
        " class=\"language-\(escapeAttribute($0))\""
      } ?? ""
    return "<pre class=\"markdown-code\"><code\(languageClass)>\(escapeText(text))</code></pre>"
  }

  private static func renderTable(
    headers: [String],
    rows: [[String]],
    alignments: [AgentMarkdownTableAlignment]
  ) -> String {
    var result = "<div class=\"markdown-table-wrap\"><table class=\"markdown-table\"><thead><tr>"
    for index in headers.indices {
      let alignment = tableAlignment(at: index, in: alignments)
      result += "<th scope=\"col\" class=\"markdown-align-\(alignmentClass(alignment))\">"
      result += inlineHTML(headers[index])
      result += "</th>"
    }
    result += "</tr></thead><tbody>"
    for row in rows {
      result += "<tr>"
      for index in headers.indices {
        let alignment = tableAlignment(at: index, in: alignments)
        let value = index < row.count ? row[index] : ""
        result += "<td class=\"markdown-align-\(alignmentClass(alignment))\">"
        result += inlineHTML(value)
        result += "</td>"
      }
      result += "</tr>"
    }
    return result + "</tbody></table></div>"
  }

  private static func tableAlignment(
    at index: Int,
    in alignments: [AgentMarkdownTableAlignment]
  ) -> AgentMarkdownTableAlignment {
    index < alignments.count ? alignments[index] : .leading
  }

  private static func alignmentClass(_ alignment: AgentMarkdownTableAlignment) -> String {
    switch alignment {
    case .leading: return "leading"
    case .center: return "center"
    case .trailing: return "trailing"
    }
  }

  static func escapeText(_ value: String) -> String {
    escape(value, newlineEntity: false)
  }

  static func escapeAttribute(_ value: String) -> String {
    escape(value, newlineEntity: true)
  }

  private static func escape(_ value: String, newlineEntity: Bool) -> String {
    var result = ""
    result.reserveCapacity(value.utf8.count)
    for character in value {
      switch character {
      case "&": result += "&amp;"
      case "<": result += "&lt;"
      case ">": result += "&gt;"
      case "\"": result += "&quot;"
      case "'": result += "&#39;"
      case "\n": result += newlineEntity ? "&#10;" : "\n"
      case "\r": result += newlineEntity ? "&#13;" : "\r"
      default: result.append(character)
      }
    }
    return result
  }
}

private final class AgentMarkdownHTMLCache: @unchecked Sendable {
  private let storage = NSCache<NSString, NSString>()

  init() {
    storage.countLimit = 128
    storage.totalCostLimit = 512_000
  }

  func value(for key: String) -> String? {
    storage.object(forKey: key as NSString) as String?
  }

  func insert(_ value: String, for key: String) {
    storage.setObject(value as NSString, forKey: key as NSString, cost: value.utf8.count)
  }
}
