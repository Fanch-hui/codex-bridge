(function (global) {
  "use strict";

  function node(tag, className, value) {
    var element = document.createElement(tag);
    if (className) element.className = className;
    if (value !== undefined && value !== null) element.textContent = value;
    return element;
  }

  function clear(element) {
    while (element && element.firstChild) element.removeChild(element.firstChild);
  }

  function icon(symbol, className) {
    var element = node("span", className || "icon");
    element.dataset.symbol = symbol || "circle.dashed";
    return element;
  }

  function badge(value, tone) {
    return node("span", "status-badge " + (tone || "neutral"), value || "未知");
  }

  function button(title, command, payload, emit, className, disabled) {
    var element = node("button", "button " + (className || ""), title);
    element.type = "button";
    element.disabled = !!disabled;
    if (command) {
      element.addEventListener("click", function () { emit(command, payload || {}); });
    }
    return element;
  }

  function selectField(label, value, choices, onChange, className) {
    var wrapper = node("div", "field " + (className || ""));
    wrapper.appendChild(node("label", null, label));
    var select = node("select");
    (choices || []).forEach(function (choice) {
      var option = node("option", null, choice.title);
      option.value = choice.id;
      option.disabled = choice.enabled === false;
      option.title = choice.detail || "";
      if (choice.id === value) option.selected = true;
      select.appendChild(option);
    });
    if (!(choices || []).some(function (choice) { return choice.id === value; }) && value) {
      var current = node("option", null, value);
      current.value = value;
      current.selected = true;
      select.insertBefore(current, select.firstChild);
    }
    select.addEventListener("change", function () { onChange(select.value); });
    wrapper.appendChild(select);
    return { wrapper: wrapper, control: select };
  }

  function textField(label, value, placeholder, className) {
    var wrapper = node("div", "field " + (className || ""));
    wrapper.appendChild(node("label", null, label));
    var input = node("input");
    input.type = "text";
    input.value = value || "";
    input.placeholder = placeholder || "";
    wrapper.appendChild(input);
    return { wrapper: wrapper, control: input };
  }

  function pageHeader(container, header) {
    clear(container);
    var element = node("div", "page-header");
    element.appendChild(icon(header.symbol, "icon-tile"));
    var copy = node("div");
    copy.appendChild(node("h2", null, header.title));
    copy.appendChild(node("p", null, header.subtitle));
    element.appendChild(copy);
    container.appendChild(element);
  }

  function section(container, title) {
    var element = node("section", "page-section");
    element.appendChild(node("h3", null, title));
    container.appendChild(element);
    return element;
  }

  function empty(container, title, description) {
    clear(container);
    var element = node("div", "empty-state");
    element.appendChild(icon("circle.dashed", "icon-tile"));
    element.appendChild(node("h2", null, title));
    element.appendChild(node("p", null, description));
    container.appendChild(element);
  }

  function choices(value, options, fallbackTitle) {
    var result = (options || []).slice();
    if (value && !result.some(function (option) { return option.id === value; })) {
      result.unshift({ id: value, title: fallbackTitle || value, enabled: true });
    }
    return result;
  }

  function safeArray(value) { return Array.isArray(value) ? value : []; }

  function markdown(value, className) {
    var root = node("div", className || "markdown-body");
    var lines = String(value || "").replace(/\r\n?/g, "\n").split("\n");
    var index = 0;
    while (index < lines.length) {
      var line = lines[index];
      if (line.trim().indexOf("```") === 0) {
        var language = line.trim().slice(3).trim();
        var codeLines = [];
        index += 1;
        while (index < lines.length && lines[index].trim().indexOf("```") !== 0) {
          codeLines.push(lines[index]);
          index += 1;
        }
        index += index < lines.length ? 1 : 0;
        var pre = node("pre", "markdown-code");
        var code = node("code", language ? "language-" + language : null, codeLines.join("\n"));
        pre.appendChild(code);
        root.appendChild(pre);
        continue;
      }
      var heading = line.match(/^(#{1,4})\s+(.+)$/);
      if (heading) {
        var h = node("h" + Math.min(heading[1].length + 2, 6));
        appendInline(h, heading[2]);
        root.appendChild(h);
        index += 1;
        continue;
      }
      if (/^\s*[-*]\s+/.test(line)) {
        var list = node("ul");
        while (index < lines.length && /^\s*[-*]\s+/.test(lines[index])) {
          var item = node("li");
          appendInline(item, lines[index].replace(/^\s*[-*]\s+/, ""));
          list.appendChild(item);
          index += 1;
        }
        root.appendChild(list);
        continue;
      }
      if (/^\s*\d+[.)]\s+/.test(line)) {
        var ordered = node("ol");
        while (index < lines.length && /^\s*\d+[.)]\s+/.test(lines[index])) {
          var orderedItem = node("li");
          appendInline(orderedItem, lines[index].replace(/^\s*\d+[.)]\s+/, ""));
          ordered.appendChild(orderedItem);
          index += 1;
        }
        root.appendChild(ordered);
        continue;
      }
      if (/^>\s?/.test(line)) {
        var quote = node("blockquote");
        appendInline(quote, line.replace(/^>\s?/, ""));
        root.appendChild(quote);
        index += 1;
        continue;
      }
      if (!line.trim()) {
        index += 1;
        continue;
      }
      var paragraphLines = [line];
      index += 1;
      while (index < lines.length && lines[index].trim() && !isBlockStart(lines[index])) {
        paragraphLines.push(lines[index]);
        index += 1;
      }
      var paragraph = node("p");
      appendInline(paragraph, paragraphLines.join("\n"));
      root.appendChild(paragraph);
    }
    return root;
  }

  function isBlockStart(line) {
    return line.trim().indexOf("```") === 0 || /^(#{1,4})\s+/.test(line)
      || /^\s*[-*]\s+/.test(line) || /^\s*\d+[.)]\s+/.test(line) || /^>\s?/.test(line);
  }

  function appendInline(container, value) {
    var source = String(value || "");
    var pattern = /(\*\*[^*]+\*\*|`[^`]+`|\[[^\]]+\]\([^)]+\))/g;
    var offset = 0;
    var match;
    while ((match = pattern.exec(source)) !== null) {
      if (match.index > offset) container.appendChild(document.createTextNode(source.slice(offset, match.index)));
      appendInlineToken(container, match[0]);
      offset = match.index + match[0].length;
    }
    if (offset < source.length) container.appendChild(document.createTextNode(source.slice(offset)));
  }

  function appendInlineToken(container, token) {
    if (token.indexOf("**") === 0) {
      container.appendChild(node("strong", null, token.slice(2, -2)));
      return;
    }
    if (token.indexOf("`") === 0) {
      container.appendChild(node("code", "markdown-inline-code", token.slice(1, -1)));
      return;
    }
    var link = token.match(/^\[([^\]]+)\]\(([^)]+)\)$/);
    if (!link || !safeWebURL(link[2])) {
      container.appendChild(document.createTextNode(token));
      return;
    }
    var anchor = node("a", null, link[1]);
    anchor.href = link[2];
    anchor.target = "_blank";
    anchor.rel = "noopener noreferrer";
    container.appendChild(anchor);
  }

  function safeWebURL(value) {
    try {
      var url = new URL(value);
      return url.protocol === "https:" || url.protocol === "http:";
    } catch (_) {
      return false;
    }
  }

  global.CodexBridgeDesktopPageSupport = {
    node: node,
    clear: clear,
    icon: icon,
    badge: badge,
    button: button,
    selectField: selectField,
    textField: textField,
    pageHeader: pageHeader,
    section: section,
    empty: empty,
    choices: choices,
    safeArray: safeArray,
    markdown: markdown
  };
}(window));
