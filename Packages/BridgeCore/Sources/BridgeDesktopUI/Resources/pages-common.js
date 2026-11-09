(function (global) {
  "use strict";
  var fieldSequence = 0, helpSequence = 0, activeHelp = null;

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

  function helpTooltipPosition(trigger, tooltip) {
    var anchor = trigger.getBoundingClientRect(), box = tooltip.getBoundingClientRect();
    var width = global.innerWidth, height = global.innerHeight, margin = 8, gap = 6;
    if (anchor.bottom <= 0 || anchor.top >= height || anchor.right <= 0 || anchor.left >= width) return false;
    var left = Math.max(margin, Math.min(anchor.left, width - box.width - margin));
    var top = anchor.top - box.height - gap;
    if (top < margin) top = anchor.bottom + gap;
    top = Math.max(margin, Math.min(top, height - box.height - margin));
    tooltip.style.left = left + "px"; tooltip.style.top = top + "px";
    return true;
  }

  function helpTooltipLayer(wrapper) {
    for (var parent = wrapper.parentNode; parent; parent = parent.parentNode) {
      if (parent.tagName && parent.tagName.toLowerCase() === "dialog" && parent.open) return parent;
    }
    return document.body;
  }

  function helpTooltip(label, description) {
    var wrapper = node("span", "help-tooltip"), trigger = node("button", "help-tooltip-trigger", "ⓘ");
    var tooltip = node("span", "help-tooltip-content", description);
    var nativePopover = typeof tooltip.showPopover === "function", opened = false;
    var triggerHovered = false, tooltipHovered = false, focused = false, closeTimer = null, dialog = null;
    tooltip.id = "desktop-help-" + (++helpSequence); tooltip.setAttribute("role", "tooltip");
    if (nativePopover) tooltip.setAttribute("popover", "manual");
    tooltip.hidden = true;
    trigger.type = "button"; trigger.setAttribute("aria-label", label);
    trigger.setAttribute("aria-describedby", tooltip.id);

    function cancelClose() { if (closeTimer) global.clearTimeout(closeTimer); closeTimer = null; }
    function place() {
      if (wrapper.isConnected === false || !helpTooltipPosition(trigger, tooltip)) close();
    }
    function close() {
      cancelClose();
      if (!opened) return;
      opened = false; tooltipHovered = false;
      if (nativePopover) tooltip.hidePopover();
      tooltip.hidden = true;
      if (!nativePopover) wrapper.appendChild(tooltip);
      document.removeEventListener("scroll", place, true);
      document.removeEventListener("keydown", escape, true);
      global.removeEventListener("resize", place);
      if (dialog) dialog.removeEventListener("close", close);
      dialog = null;
      if (activeHelp === close) activeHelp = null;
    }
    function escape(event) {
      if (event.key !== "Escape") return;
      event.preventDefault(); event.stopPropagation(); close();
    }
    function show() {
      cancelClose();
      if (opened) { place(); return; }
      if (activeHelp) activeHelp();
      var layer = helpTooltipLayer(wrapper);
      dialog = layer !== document.body ? layer : null;
      if (!nativePopover) layer.appendChild(tooltip);
      tooltip.hidden = false;
      if (nativePopover) tooltip.showPopover();
      opened = true; activeHelp = close;
      document.addEventListener("scroll", place, true);
      document.addEventListener("keydown", escape, true);
      global.addEventListener("resize", place);
      if (dialog) dialog.addEventListener("close", close);
      place();
    }
    function closeWhenIdle() {
      cancelClose();
      if (triggerHovered || tooltipHovered || focused) return;
      closeTimer = global.setTimeout(close, 150);
    }
    trigger.addEventListener("mouseenter", function () { triggerHovered = true; show(); });
    trigger.addEventListener("mouseleave", function () { triggerHovered = false; closeWhenIdle(); });
    tooltip.addEventListener("mouseenter", function () { tooltipHovered = true; cancelClose(); });
    tooltip.addEventListener("mouseleave", function () { tooltipHovered = false; closeWhenIdle(); });
    trigger.addEventListener("focus", function () { focused = true; show(); });
    trigger.addEventListener("blur", function () { focused = false; closeWhenIdle(); });
    trigger.addEventListener("click", function (event) { event.preventDefault(); event.stopPropagation(); });
    trigger.addEventListener("keydown", function (event) {
      if (event.key === "Enter" || event.key === " ") event.stopPropagation();
    });
    wrapper.appendChild(trigger); wrapper.appendChild(tooltip);
    return wrapper;
  }

  function badge(value, tone) {
    return node("span", "status-badge " + (tone || "neutral"), value || "未知");
  }

  function status(value, tone) {
    var element = node("span");
    updateStatus(element, value, tone);
    return element;
  }

  function updateStatus(element, value, tone) {
    var label = value || "未知", kind = tone || "neutral";
    var actionable = /排队|等待|审批|暂停|取消|失败|不可|异常|未知|未连接/.test(label)
      || /queued|pending|approval|failed|unavailable|unknown/.test(label);
    var quiet = !actionable && (kind === "success" || kind === "running");
    element.className = "status-indicator " + kind + (quiet ? " is-quiet" : "");
    element.setAttribute("role", "img");
    element.title = label; element.setAttribute("aria-label", label);
    clear(element);
    var symbol = kind === "success" ? "checkmark.circle.fill"
      : kind === "error" ? "xmark.circle.fill"
      : kind === "warning" ? "exclamationmark.triangle.fill" : "circle.dashed";
    element.appendChild(icon(symbol, "status-icon"));
    if (!quiet) element.appendChild(node("span", "status-label", label));
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

  function field(label, control, className) {
    var wrapper = node("div", "field " + (className || ""));
    var caption = node("label", null, label);
    control.id = "desktop-field-" + (++fieldSequence);
    control.setAttribute("aria-label", label);
    caption.htmlFor = control.id;
    wrapper.appendChild(caption);
    wrapper.appendChild(control);
    return { wrapper: wrapper, control: control };
  }

  function selectField(label, value, choices, onChange, className) {
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
    return field(label, select, className);
  }

  function textField(label, value, placeholder, className) {
    var input = node("input");
    input.type = "text";
    input.value = value || "";
    input.placeholder = placeholder || "";
    return field(label, input, className);
  }

  function textAreaField(label, value, placeholder, className) {
    var input = node("textarea");
    input.value = value || "";
    input.placeholder = placeholder || "";
    input.rows = 1;
    input.wrap = "soft";
    return field(label, input, className);
  }

  function autoGrowTextArea(control) {
    if (!control || !control.style) return;
    control.style.height = "auto";
    var border = Math.max(0, (control.offsetHeight || 0) - (control.clientHeight || 0));
    var height = Math.max((control.scrollHeight || 0) + border, 32);
    // A composer may cap its height in CSS (split panes use a lower limit than the default 180px).
    var styled = global.getComputedStyle ? parseFloat(global.getComputedStyle(control).maxHeight) : NaN;
    var maxHeight = styled > 0 ? styled : 180;
    control.style.height = Math.min(height, maxHeight) + "px";
    control.style.overflowY = height > maxHeight ? "auto" : "hidden";
  }

  function pageHeader(container, header) {
    var help = container.__pageHelp;
    if (!help) {
      help = container.__pageHelp = node("details", "page-help");
      help.appendChild(node("summary", null, "说明"));
      help.appendChild(node("p"));
      container.appendChild(help);
    }
    help.hidden = !header.subtitle;
    help.lastChild.textContent = header.subtitle || "";
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

  // Native selects are as wide as their longest option, which leaves empty space after a short
  // choice. Composer pickers are sized to the selected text instead: `field-sizing: content`
  // does this where supported, and the measurement below covers WKWebView and WebKitGTK builds
  // that lack it. Width is re-measured whenever the value is set or the user changes it.
  var measureContext;
  function fitSelect(select) {
    if (!select || typeof global.getComputedStyle !== "function") return;
    var style = global.getComputedStyle(select), option = select.options && select.options[select.selectedIndex];
    if (!style || !style.fontSize) return;
    if (measureContext === undefined) {
      var canvas = document.createElement("canvas");
      measureContext = typeof canvas.getContext === "function" && canvas.getContext("2d") || null;
    }
    if (!measureContext || !option) { select.style.width = ""; return; }
    measureContext.font = [style.fontStyle, style.fontWeight, style.fontSize, style.fontFamily].join(" ");
    var box = style.boxSizing === "border-box" ? ["paddingLeft", "paddingRight", "borderLeftWidth", "borderRightWidth"]
      .reduce(function (sum, name) { return sum + (parseFloat(style[name]) || 0); }, 0) : 0;
    select.style.width = Math.ceil(measureContext.measureText(option.textContent || "").width + box) + 2 + "px";
  }
  function autoFitSelect(select) {
    if (!select || select.__autoFit || typeof global.getComputedStyle !== "function") return select;
    select.__autoFit = true;
    var queued = false, accessor = null;
    for (var owner = select; owner && !accessor; owner = Object.getPrototypeOf(owner)) {
      accessor = Object.getOwnPropertyDescriptor(owner, "value");
    }
    function schedule() {
      if (queued) return;
      queued = true;
      (global.requestAnimationFrame || global.setTimeout)(function () { queued = false; fitSelect(select); });
    }
    if (accessor && accessor.get && accessor.set) {
      Object.defineProperty(select, "value", { configurable: true, get: function () { return accessor.get.call(select); },
        set: function (value) { accessor.set.call(select, value); schedule(); } });
    }
    select.addEventListener("change", function () { fitSelect(select); });
    schedule();
    return select;
  }

  // The default workspace is where work starts when no project is chosen; the host reports it
  // as `defaultProjectID`, and the first listed project stands in until that arrives.
  function defaultProjectID(page) {
    var projects = safeArray(page && page.projects);
    return page && page.defaultProjectID || projects[0] && projects[0].id || null;
  }

  // Splits rows into project groups: the default workspace first, then the project list order,
  // then projects that are no longer listed. Rows without a project belong to the default
  // workspace and groups without rows are omitted.
  function groupByProject(rows, projects, defaultID, projectOf, titleOf) {
    var titles = new Map(), order = defaultID ? [defaultID] : [], buckets = new Map();
    safeArray(projects).forEach(function (project) {
      titles.set(project.id, project.title);
      if (order.indexOf(project.id) < 0) order.push(project.id);
    });
    safeArray(rows).forEach(function (row) {
      var id = projectOf(row) || defaultID || "";
      if (!buckets.has(id)) buckets.set(id, []);
      buckets.get(id).push(row);
      if (order.indexOf(id) < 0) order.push(id);
    });
    return order.filter(function (id) { return buckets.has(id); }).map(function (id) {
      var rowsOfProject = buckets.get(id);
      return { projectID: id, rows: rowsOfProject, title: titles.get(id) || titleOf && titleOf(rowsOfProject[0]) || "其他" };
    });
  }

  var collapsedKey = "codexbridge.workbench.collapsed-groups.v1", collapsedGroups = null;
  function groupCollapsed(scope, projectID, value) {
    if (!collapsedGroups) {
      try { collapsedGroups = new Set(JSON.parse(global.localStorage.getItem(collapsedKey) || "[]")); } catch (_) { collapsedGroups = new Set(); }
    }
    var id = scope + "\u001f" + projectID;
    if (value === undefined) return collapsedGroups.has(id);
    if (value) collapsedGroups.add(id); else collapsedGroups.delete(id);
    try { global.localStorage.setItem(collapsedKey, JSON.stringify(Array.from(collapsedGroups))); } catch (_) {}
    return value;
  }

  // One collapsible project group of a sidebar list; the caller fills `body` with its rows.
  // Collapsing only toggles the existing nodes so a list render never races with the click.
  function projectGroup(group, options) {
    var root = node("section"), header = node("div", "dsh-group-header"), body = node("div", "dsh-group-sessions");
    var toggle = node("button", "dsh-group-toggle");
    toggle.type = "button"; toggle.title = group.title; toggle.dataset.groupId = group.projectID;
    toggle.appendChild(icon("chevron.down", "dsh-group-chevron"));
    toggle.appendChild(node("span", "dsh-group-title", group.title));
    function setCollapsed(value) {
      body.hidden = value; toggle.setAttribute("aria-expanded", String(!value));
      root.className = "dsh-project-group" + (value ? " is-collapsed" : "");
    }
    toggle.addEventListener("click", function () { setCollapsed(groupCollapsed(options.scope, group.projectID, !body.hidden)); });
    setCollapsed(groupCollapsed(options.scope, group.projectID));
    header.appendChild(toggle);
    if (options.onNew) {
      var add = node("button", "dsh-group-new");
      add.type = "button"; add.title = options.newLabel + "：" + group.title;
      add.setAttribute("aria-label", add.title); add.dataset.groupId = group.projectID; add.dataset.groupNew = "";
      add.appendChild(icon("plus"));
      add.addEventListener("click", function () { options.onNew(group.projectID); });
      header.appendChild(add);
    }
    root.appendChild(header); root.appendChild(body);
    return { root: root, body: body };
  }

  // WebKit (macOS WKWebView, WebKitGTK) delivers the Enter that confirms an input method
  // candidate after compositionend, with isComposing false and keyCode 229. Such a key only
  // commits the typed text and must never send a message.
  var lastCompositionEnd = -1;
  if (global.document && typeof global.document.addEventListener === "function") {
    global.document.addEventListener("compositionend", function (event) {
      lastCompositionEnd = event.timeStamp;
    }, true);
  }
  // WebKit matches :focus-visible for selects and other controls focused by a click, which
  // draws focus rings after ordinary mouse use. The last input modality lets the styles keep
  // rings for keyboard navigation only. Popup menus built from `details[data-popup]` close
  // when the user presses outside them or Escape.
  if (global.document && typeof global.document.addEventListener === "function") {
    var rootElement = global.document.documentElement;
    var setModality = function (value) {
      if (rootElement && rootElement.dataset.inputModality !== value) rootElement.dataset.inputModality = value;
    };
    var closePopups = function (except) {
      global.document.querySelectorAll("details[data-popup][open]").forEach(function (popup) {
        if (!except || !popup.contains(except)) popup.open = false;
      });
    };
    global.document.addEventListener("pointerdown", function (event) {
      setModality("pointer");
      closePopups(event.target);
    }, true);
    global.document.addEventListener("toggle", function (event) {
      var target = event.target, pages = global.CodexBridgeDesktopPages, ui = global.CodexBridgeDesktopUI;
      if (!target || !target.dataset || target.dataset.popup === undefined || !pages || !ui) return;
      pages.measureBrowserViewport(ui.sendCommand);
    }, true);
    global.document.addEventListener("keydown", function (event) {
      if (event.key === "Tab" || event.key.indexOf("Arrow") === 0) setModality("keyboard");
      if (event.key === "Escape") closePopups(null);
    }, true);
  }

  function isIMEKeyEvent(event) {
    if (!event) return false;
    if (event.isComposing || event.keyCode === 229) return true;
    return lastCompositionEnd >= 0 && event.timeStamp - lastCompositionEnd >= 0
      && event.timeStamp - lastCompositionEnd < 100;
  }

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
    helpTooltip: helpTooltip,
    badge: badge,
    status: status,
    updateStatus: updateStatus,
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
    autoGrowTextArea: autoGrowTextArea,
    fitSelect: fitSelect,
    autoFitSelect: autoFitSelect,
    defaultProjectID: defaultProjectID,
    groupByProject: groupByProject,
    projectGroup: projectGroup,
    isIMEKeyEvent: isIMEKeyEvent
  };
}(window));
