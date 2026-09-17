(function () {
  "use strict";

  var state = null;
  var requestSequence = 0;
  var navigationNodes = new Map();
  var iconPaths = window.CodexBridgeDesktopIcons;

  function iconMarkup(symbol) {
    return '<svg viewBox="0 0 24 24" aria-hidden="true">' + (iconPaths[symbol] || iconPaths["circle.dashed"]) + "</svg>";
  }

  function setIcons(root) {
    Array.prototype.forEach.call((root || document).querySelectorAll("[data-symbol]"), function (node) {
      node.innerHTML = iconMarkup(node.getAttribute("data-symbol"));
    });
  }

  function toneClass(tone) { return tone || "neutral"; }

  function applyHostContext(context) {
    var root = document.documentElement;
    if (context && context.platform) {
      root.dataset.platform = context.platform;
    } else if (root.dataset.platform !== "windows") {
      root.removeAttribute("data-platform");
    }
  }

  function renderFeedback(feedback) {
    if (window.CodexBridgeDesktopFeedback) {
      window.CodexBridgeDesktopFeedback.render(feedback, emit);
    }
  }

  function emit(command, payload) {
    var envelope = { version: 1, requestID: "desktop-ui-" + (++requestSequence), command: command, payload: payload || {} };
    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.bridgeDesktopUI) {
      window.webkit.messageHandlers.bridgeDesktopUI.postMessage(envelope);
    }
    if (window.chrome && window.chrome.webview && window.chrome.webview.postMessage) {
      window.chrome.webview.postMessage(envelope);
    }
    window.dispatchEvent(new CustomEvent("codex-bridge-command", { detail: envelope }));
  }

  function renderNavigation(items, selected) {
    var container = document.getElementById("navigation"), active = new Set();
    (items || []).forEach(function (item, index) {
      active.add(item.navigation);
      var button = navigationNodes.get(item.navigation);
      if (!button) {
        button = document.createElement("button"); button.type = "button";
        button.appendChild(iconElement(item.symbol, "icon"));
        button.appendChild(elementWithText("span", "nav-title", item.title));
        button.appendChild(elementWithText("span", "nav-badge", ""));
        button.addEventListener("click", function () { emit("selectPage", { navigation: item.navigation }); });
        navigationNodes.set(item.navigation, button);
        setIcons(button);
      }
      button.title = item.title; button.setAttribute("aria-label", item.title);
      button.className = "nav-item" + (item.navigation === selected ? " is-selected" : "");
      button.setAttribute("aria-current", item.navigation === selected ? "page" : "false");
      button.querySelector(".nav-title").textContent = item.title;
      var badge = button.querySelector(".nav-badge");
      badge.hidden = item.badge == null; badge.textContent = item.badge == null ? "" : item.badge;
      if (container.children[index] !== button) container.insertBefore(button, container.children[index] || null);
    });
    navigationNodes.forEach(function (button, key) {
      if (!active.has(key)) { button.remove(); navigationNodes.delete(key); }
    });
  }

  function iconElement(symbol, className) {
    var element = document.createElement("span");
    element.className = className || "icon";
    element.dataset.symbol = symbol;
    return element;
  }

  function elementWithText(tag, className, value) {
    var element = document.createElement(tag);
    element.className = className;
    element.textContent = value || "";
    return element;
  }

  function renderMetric(metric) {
    var button = document.createElement("button");
    button.type = "button";
    button.className = "metric-card tone-" + toneClass(metric.tone);
    var top = document.createElement("span");
    top.className = "metric-topline";
    top.appendChild(elementWithText("span", "metric-title", metric.title));
    top.appendChild(iconElement(metric.symbol, "metric-icon"));
    button.appendChild(top);
    var value = document.createElement("span");
    value.className = "metric-value";
    value.appendChild(elementWithText("span", "metric-number", metric.value));
    if (metric.destination) value.appendChild(elementWithText("span", "metric-chevron", "›"));
    button.appendChild(value);
    button.appendChild(elementWithText("span", "metric-subtitle", metric.subtitle));
    if (metric.destination) button.addEventListener("click", function () { emit("selectPage", { navigation: metric.destination }); });
    return button;
  }

  function renderOverview(overview) {
    if (!overview) return;
    document.getElementById("overview-title").textContent = overview.title;
    document.getElementById("overview-subtitle").textContent = overview.subtitle;
    var metrics = document.getElementById("metrics");
    metrics.innerHTML = "";
    (overview.metrics || []).forEach(function (metric) { metrics.appendChild(renderMetric(metric)); });
    setIcons(metrics);
    renderServices(overview.services, overview.serviceActions);
    renderRecentTasks(overview.recentTasks);
    renderNotices(overview.notices);
  }

  function renderServices(rows, actions) {
    var container = document.getElementById("services");
    container.innerHTML = "";
    (rows || []).forEach(function (row) {
      var element = document.createElement(row.destination ? "button" : "div");
      element.className = "service-row tone-" + toneClass(row.tone);
      if (row.destination) { element.type = "button"; element.addEventListener("click", function () { emit("selectPage", { navigation: row.destination }); }); }
      element.appendChild(iconElement(row.symbol, "service-icon"));
      element.appendChild(elementWithText("span", "service-title", row.title));
      element.appendChild(elementWithText("span", "status-badge " + toneClass(row.tone), row.value));
      container.appendChild(element);
    });
    if (actions && actions.length) {
      var actionBar = document.createElement("div");
      actionBar.className = "service-actions";
      actions.forEach(function (action) {
        var button = document.createElement("button");
        button.type = "button";
        button.className = "link-button";
        button.textContent = action.title;
        button.addEventListener("click", function () { emit(action.command, { navigation: action.destination || null, taskID: action.taskID || null }); });
        actionBar.appendChild(button);
      });
      container.appendChild(actionBar);
    }
    setIcons(container);
  }

  function renderRecentTasks(tasks) {
    var section = document.getElementById("recent-section");
    var container = document.getElementById("recent-tasks");
    section.hidden = !tasks || tasks.length === 0;
    container.innerHTML = "";
    (tasks || []).forEach(function (task) {
      var row = document.createElement("button");
      row.type = "button";
      row.className = "recent-task";
      row.appendChild(elementWithText("span", "status-badge neutral recent-status", task.status));
      row.appendChild(elementWithText("span", "recent-source", task.source));
      var copy = document.createElement("span");
      copy.appendChild(elementWithText("span", "recent-title", task.title));
      copy.appendChild(elementWithText("span", "recent-project", task.projectName));
      row.appendChild(copy);
      row.appendChild(elementWithText("span", "recent-time", task.updatedAt));
      row.appendChild(elementWithText("span", "recent-chevron", "›"));
      row.addEventListener("click", function () { emit("openTask", { taskID: task.id }); });
      container.appendChild(row);
    });
  }

  function renderNotices(notices) {
    var container = document.getElementById("notices");
    container.innerHTML = "";
    (notices || []).forEach(function (notice) {
      var element = document.createElement("div");
      element.className = "notice " + toneClass(notice.tone);
      element.appendChild(iconElement(notice.symbol, "icon"));
      var copy = document.createElement("div");
      copy.appendChild(document.createElement("h4"));
      copy.lastChild.textContent = notice.title;
      copy.appendChild(document.createElement("p"));
      copy.lastChild.textContent = notice.message;
      element.appendChild(copy);
      if (notice.command || notice.destination) {
        var action = document.createElement("button");
        action.type = "button";
        action.className = "link-button";
        action.textContent = notice.command === "openSystemSettings" ? "打开登录项设置" : "处理 →";
        action.addEventListener("click", function () {
          if (notice.command) {
            emit(notice.command, { navigation: notice.destination || null });
          } else {
            emit("selectPage", { navigation: notice.destination });
          }
        });
        element.appendChild(action);
      }
      container.appendChild(element);
    });
    setIcons(container);
  }

  function renderState(nextState) {
    state = nextState;
    applyHostContext(state && state.hostContext);
    var shell = document.getElementById("app-shell");
    var loading = document.getElementById("loading-state");
    loading.hidden = !!state;
    shell.dataset.state = state ? "ready" : "loading";
    if (!state) {
      renderFeedback(null);
      globalPages(null, emit);
      return;
    }
    renderNavigation(state.navigation, state.selectedNavigation);
    var selectedItem = (state.navigation || []).find(function (item) { return item.navigation === state.selectedNavigation; }) || {};
    var pageState = state[state.selectedNavigation];
    document.getElementById("page-title").textContent = state.selectedNavigation === "overview" && state.overview
      ? state.overview.title : pageState && pageState.header ? pageState.header.title : selectedItem.title || "Codex Bridge";
    var indicator = document.getElementById("connection-indicator");
    indicator.className = "connection-indicator " + toneClass(state.connectionTone);
    document.getElementById("connection-label").textContent = state.connectionLabel;
    document.getElementById("refresh-indicator").classList.toggle("is-visible", !!state.isRefreshing);
    document.querySelector(".refresh-button").classList.toggle("is-refreshing", !!state.isRefreshing);
    document.querySelector(".refresh-button").disabled = !!state.isRefreshing;
    renderFeedback(state.feedback);
    if (state.selectedNavigation === "overview") renderOverview(state.overview);
    globalPages(state, emit);
    setIcons(document);
  }

  function globalPages(nextState, commandEmitter) {
    if (window.CodexBridgeDesktopPages) window.CodexBridgeDesktopPages.render(nextState, commandEmitter);
  }

  document.addEventListener("click", function (event) {
    var link = event.target.closest("a[href]");
    if (link) {
      event.preventDefault();
      try {
        var url = new URL(link.href);
        if (url.protocol === "http:" || url.protocol === "https:") emit("openExternalURL", { value: url.href });
      } catch (_) {}
      return;
    }
    var action = event.target.closest("[data-action]");
    if (!action) return;
    if (action.dataset.action === "refresh") emit("refresh");
    if (action.dataset.action === "select-page") emit("selectPage", { navigation: action.dataset.page });
  });
  document.addEventListener("contextmenu", function (event) {
    if (document.documentElement.dataset.platform === "windows") {
      event.preventDefault();
    }
  });
  window.addEventListener("resize", function () {
    if (state && state.selectedNavigation === "workbench" && window.CodexBridgeDesktopPages) window.CodexBridgeDesktopPages.measureBrowserViewport(emit);
  });
  var contentScroller = document.querySelector(".content-scroll");
  if (contentScroller) {
    contentScroller.addEventListener("scroll", function () {
      if (state && state.selectedNavigation === "workbench" && window.CodexBridgeDesktopPages) {
        window.requestAnimationFrame(function () { window.CodexBridgeDesktopPages.measureBrowserViewport(emit); });
      }
    }, { passive: true });
  }

  window.CodexBridgeDesktopUI = { setState: renderState, getState: function () { return state; }, sendCommand: emit };
  if (window.chrome && window.chrome.webview && window.chrome.webview.addEventListener) {
    window.chrome.webview.addEventListener("message", function (event) {
      var incoming = event.data;
      if (typeof incoming === "string") { try { incoming = JSON.parse(incoming); } catch (_) { return; } }
      if (incoming && typeof incoming === "object") renderState(incoming);
    });
  }
  setIcons(document);
  emit("ready");
}());
