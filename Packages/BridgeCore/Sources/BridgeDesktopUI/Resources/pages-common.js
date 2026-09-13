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
