(function (global) {
  "use strict";

  function escape(value) {
    return String(value).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;").replace(/'/g, "&#39;");
  }

  function safeURL(value) {
    if (!/^https?:\/\//i.test(value) || /[\u0000-\u0020\u007f\\]/.test(value)) return false;
    try {
      var url = new URL(value);
      return (url.protocol === "https:" || url.protocol === "http:") && !!url.hostname && !url.username && !url.password;
    } catch (_) { return false; }
  }

  function inline(text, depth, budget) {
    if (depth > 4) return escape(text);
    budget = budget || { remaining: Math.max(64, text.length * 8) };
    var html = "", index = 0;
    function find(marker, from) {
      var result = text.indexOf(marker, from);
      budget.remaining -= (result < 0 ? text.length : result + marker.length) - from;
      return result;
    }
    while (index < text.length) {
      if (budget.remaining <= 0) return html + escape(text.slice(index));
      var char = text[index], end;
      if (char === "\\" && index + 1 < text.length && /[\\`*_{}\[\]()#+.!~>|-]/.test(text[index + 1])) {
        html += escape(text[index + 1]); index += 2; continue;
      }
      if (char === "`") {
        var size = 1;
        while (text[index + size] === "`") size++;
        var tick = "`".repeat(size); end = find(tick, index + size);
        if (end >= 0) {
          html += '<code class="markdown-inline-code">' + escape(text.slice(index + size, end)) + "</code>";
          index = end + size; continue;
        }
      }
      var image = char === "!" && text[index + 1] === "[";
      if (char === "[" || image) {
        var labelStart = index + (image ? 2 : 1), labelEnd = find("](", labelStart);
        if (labelEnd >= 0) {
          var urlEnd = find(")", labelEnd + 2);
          if (urlEnd >= 0) {
            var label = text.slice(labelStart, labelEnd), url = text.slice(labelEnd + 2, urlEnd).trim();
            if (safeURL(url)) {
              html += (image ? "!" : "") + '<a href="' + escape(url) + '" target="_blank" rel="noopener noreferrer">' + inline(label, depth + 1, budget) + "</a>";
              index = urlEnd + 1; continue;
            }
          }
        }
      }
      var marker = text.slice(index, index + 2);
      if (["**", "__", "~~"].includes(marker)) {
        end = find(marker, index + 2);
        if (end > index + 2) {
          var tag = marker === "~~" ? "del" : "strong";
          html += "<" + tag + ">" + inline(text.slice(index + 2, end), depth + 1, budget) + "</" + tag + ">";
          index = end + 2; continue;
        }
      }
      if (char === "*" || char === "_") {
        var intraword = char === "_" && /[\p{L}\p{N}]/u.test(text[index - 1] || "");
        end = intraword ? -1 : find(char, index + 1);
        if (end > index + 1) {
          html += "<em>" + inline(text.slice(index + 1, end), depth + 1, budget) + "</em>";
          index = end + 1; continue;
        }
      }
      html += escape(char); index++;
    }
    return html;
  }

  function cells(line) {
    var text = line.trim().replace(/^\|/, "").replace(/\|$/, "");
    return text.split(/(?<!\\)\|/).map(function (cell) { return cell.replace(/\\\|/g, "|").trim(); });
  }
  function isTableSeparator(line) {
    var parts = cells(line);
    return parts.length > 1 && parts.every(function (part) { return /^:?-{3,}:?$/.test(part); });
  }
  function isBlock(line) {
    return /^\s*(```|~~~|#{1,6}\s|>|(?:[-+*]|\d+[.)])\s|(?:-{3,}|\*{3,}|_{3,})\s*$)/.test(line);
  }

  function render(value, depth) {
    depth = depth || 0;
    if (depth > 8) return "<p>" + escape(value) + "</p>";
    var lines = String(value || "").replace(/\r\n?/g, "\n").split("\n"), html = [], i = 0;
    while (i < lines.length) {
      var line = lines[i];
      if (!line.trim()) { i++; continue; }
      var fence = line.match(/^\s*(`{3,}|~{3,})\s*([^\s`]*)?.*$/);
      if (fence) {
        var code = [], token = fence[1], char = token[0]; i++;
        while (i < lines.length && !new RegExp("^\\s*" + char + "{" + token.length + ",}\\s*$").test(lines[i])) code.push(lines[i++]);
        if (i < lines.length) i++;
        html.push('<pre class="markdown-code-block"><code>' + escape(code.join("\n")) + "</code></pre>"); continue;
      }
      var heading = line.match(/^\s*(#{1,6})\s+(.+?)\s*#*\s*$/);
      if (heading) { var level = heading[1].length; html.push("<h" + level + ">" + inline(heading[2], 0) + "</h" + level + ">"); i++; continue; }
      if (/^\s*(?:-{3,}|\*{3,}|_{3,})\s*$/.test(line)) { html.push("<hr>"); i++; continue; }
      if (line.includes("|") && i + 1 < lines.length && isTableSeparator(lines[i + 1])) {
        var headers = cells(line), alignment = cells(lines[i + 1]);
        if (headers.length === alignment.length) {
          var classes = alignment.map(function (cell) { return /^:-+:$/.test(cell) ? "center" : /:$/.test(cell) ? "trailing" : "leading"; });
          function row(values, tag) { return "<tr>" + headers.map(function (_, index) {
            return "<" + tag + ' class="markdown-align-' + classes[index] + '">' + inline(values[index] || "", 0) + "</" + tag + ">";
          }).join("") + "</tr>"; }
          html.push('<div class="markdown-table-wrap"><table class="markdown-table"><thead>' + row(headers, "th") + "</thead><tbody>");
          i += 2; while (i < lines.length && lines[i].trim() && lines[i].includes("|")) html.push(row(cells(lines[i++]), "td"));
          html.push("</tbody></table></div>"); continue;
        }
      }
      var item = line.match(/^\s*([-+*]|\d+[.)])\s+(.+)$/);
      if (item) {
        var ordered = /^\d/.test(item[1]), list = ordered ? "ol" : "ul";
        html.push("<" + list + ">");
        do {
          html.push("<li>" + inline(item[2], 0) + "</li>"); i++;
          item = i < lines.length && lines[i].match(/^\s*([-+*]|\d+[.)])\s+(.+)$/);
        } while (item && /^\d/.test(item[1]) === ordered);
        html.push("</" + list + ">"); continue;
      }
      if (/^\s*>/.test(line)) {
        var quote = [];
        while (i < lines.length && /^\s*>/.test(lines[i])) quote.push(lines[i++].replace(/^\s*>\s?/, ""));
        html.push("<blockquote>" + render(quote.join("\n"), depth + 1) + "</blockquote>"); continue;
      }
      var paragraph = [line]; i++;
      while (i < lines.length && lines[i].trim() && !isBlock(lines[i])
        && !(lines[i].includes("|") && i + 1 < lines.length && isTableSeparator(lines[i + 1]))) paragraph.push(lines[i++]);
      html.push("<p>" + paragraph.map(function (part) { return inline(part, 0); }).join("<br>") + "</p>");
    }
    return html.join("");
  }
  global.CodexBridgeDesktopEmbeddedDSHMarkdown = { render: render };
}(window));
