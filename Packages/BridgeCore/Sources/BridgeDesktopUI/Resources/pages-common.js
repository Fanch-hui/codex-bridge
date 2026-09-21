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
    var element = node("span", "icon" + (className ? " " + className : ""));
    element.dataset.symbol = symbol || "circle.dashed";
    var icons = global.CodexBridgeDesktopIcons;
    if (icons) element.innerHTML = '<svg viewBox="0 0 24 24" aria-hidden="true">'
      + (icons[element.dataset.symbol] || icons["circle.dashed"]) + "</svg>";
    return element;
  }

  function badge(value, tone) {
    return node("span", "status-badge " + (tone || "neutral"), value || "未知");
  }

  function gitStateBadge(gitState) {
    if (gitState === null || gitState === undefined || gitState === "") return null;
    switch (gitState) {
      case "clean": return { label: "Git干净", tone: "success" };
      case "dirty": return { label: "有未提交改动", tone: "warning" };
      case "not_git": return { label: "非Git项目", tone: "neutral" };
      case "check_failed": return { label: "检查失败", tone: "error" };
      default: return { label: "检查失败", tone: "error" };
    }
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

  function textAreaField(label, value, placeholder, className) {
    var wrapper = node("div", "field " + (className || ""));
    wrapper.appendChild(node("label", null, label));
    var input = node("textarea");
    input.value = value || "";
    input.placeholder = placeholder || "";
    input.rows = 1;
    input.wrap = "soft";
    wrapper.appendChild(input);
    return { wrapper: wrapper, control: input };
  }

  function autoGrowTextArea(control) {
    if (!control || !control.style) return;
    control.style.height = "auto";
    var height = Math.max(control.scrollHeight || 0, 32);
    var maxHeight = 180;
    control.style.height = Math.min(height, maxHeight) + "px";
    control.style.overflowY = height > maxHeight ? "auto" : "hidden";
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

  function markdown(value, className, html) {
    var root = node("div", className || "markdown-body");
    if (typeof html === "string") root.innerHTML = html;
    else if (typeof value === "string") root.textContent = value;
    return root;
  }

  global.CodexBridgeDesktopPageSupport = {
    node: node,
    clear: clear,
    icon: icon,
    badge: badge,
    gitStateBadge: gitStateBadge,
    button: button,
    selectField: selectField,
    textField: textField,
    pageHeader: pageHeader,
    section: section,
    empty: empty,
    choices: choices,
    safeArray: safeArray,
    markdown: markdown,
    textAreaField: textAreaField,
    autoGrowTextArea: autoGrowTextArea
  };
}(window));
