(function () {
  "use strict";

  var state = null;
  var requestSequence = 0;
  var iconPaths = {
    "gauge.with.needle": '<path d="M4 14a8 8 0 1 1 16 0"/><path d="m12 12 4-4"/><path d="M5.5 17h13"/>',
    "bubble.left.and.text.bubble.right.fill": '<path d="M4 5.5A3.5 3.5 0 0 1 7.5 2h5A3.5 3.5 0 0 1 16 5.5v3A3.5 3.5 0 0 1 12.5 12H9l-3.5 2v-2.4A3.5 3.5 0 0 1 4 8.5z"/><path d="M10 14.5A3.5 3.5 0 0 0 13.5 18h2l3 2v-2.3A3.5 3.5 0 0 0 20 15v-1"/>',
    "folder.fill": '<path d="M3 6.5A2.5 2.5 0 0 1 5.5 4H9l2 2h7.5A2.5 2.5 0 0 1 21 8.5v7A2.5 2.5 0 0 1 18.5 18h-13A2.5 2.5 0 0 1 3 15.5z"/>',
    "list.dash.header.rectangle": '<rect x="3" y="4" width="18" height="16" rx="2"/><path d="M3 9h18M7 13h3M7 16h6"/>',
    "point.3.connected.trianglepath.dotted": '<circle cx="5" cy="6" r="2"/><circle cx="19" cy="6" r="2"/><circle cx="12" cy="18" r="2"/><path d="m7 7 3.5 8M17 7l-3.5 8M7 6h10"/>',
    "gearshape": '<circle cx="12" cy="12" r="3"/><path d="m19 13 2-1-2-1-.5-2 1-1.7-2.3-2.3-1.7 1-2-.5-1-2-1 2-2 .5-1.7-1L5.5 6.3l1 1.7-.5 2-2 1 2 1 .5 2-1 1.7 2.3 2.3 1.7-1 2 .5 1 2 1-2 2-.5 1.7 1 2.3-2.3-1-1.7z"/>',
    "sidebar.left": '<rect x="3" y="4" width="18" height="16" rx="2"/><path d="M9 4v16M6 8h1M6 11h1"/>',
    "arrow.clockwise": '<path d="M20 11a8 8 0 0 0-14-4L4 9"/><path d="M4 5v4h4M4 13a8 8 0 0 0 14 4l2-2"/><path d="M20 19v-4h-4"/>',
    "bolt.fill": '<path d="m13 2-8 11h6l-1 9 8-12h-6z"/>',
    "shield.lefthalf.filled": '<path d="M12 3 5 6v5c0 4.5 3 8 7 10 4-2 7-5.5 7-10V6z"/><path d="M12 3v18"/>',
    "cpu.fill": '<rect x="7" y="7" width="10" height="10" rx="1"/><path d="M9 1v4M15 1v4M9 19v4M15 19v4M1 9h4M1 15h4M19 9h4M19 15h4"/>',
    "list.bullet.rectangle": '<rect x="4" y="3" width="16" height="18" rx="2"/><path d="M8 8h8M8 12h8M8 16h5"/>',
    "checkmark.circle.fill": '<circle cx="12" cy="12" r="9"/><path d="m8 12 2.5 2.5L16 9"/>',
    "circle.dashed": '<circle cx="12" cy="12" r="8" stroke-dasharray="3 3"/>',
    "link": '<path d="m9 15-2 2a3 3 0 0 1-4-4l3-3a3 3 0 0 1 4 0M15 9l2-2a3 3 0 0 1 4 4l-3 3a3 3 0 0 1-4 0M8 16l8-8"/>'
  };

  function iconMarkup(symbol) {
    return '<svg viewBox="0 0 24 24" aria-hidden="true">' + (iconPaths[symbol] || iconPaths["circle.dashed"]) + '</svg>';
  }

  function setIcons(root) {
    Array.prototype.forEach.call((root || document).querySelectorAll("[data-symbol]"), function (node) {
      node.innerHTML = iconMarkup(node.getAttribute("data-symbol"));
    });
  }

  function toneClass(tone) {
    return tone || "neutral";
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
    var container = document.getElementById("navigation");
    container.innerHTML = "";
    (items || []).forEach(function (item) {
      var button = document.createElement("button");
      button.type = "button";
      button.className = "nav-item" + (item.navigation === selected ? " is-selected" : "");
      button.setAttribute("data-page", item.navigation);
      button.setAttribute("aria-current", item.navigation === selected ? "page" : "false");
      button.innerHTML = '<span class="icon" data-symbol="' + item.symbol + '"></span><span class="nav-title"></span>' + (item.badge === null || item.badge === undefined ? "" : '<span class="nav-badge"></span>');
      button.querySelector(".nav-title").textContent = item.title;
      if (button.querySelector(".nav-badge")) button.querySelector(".nav-badge").textContent = item.badge;
      button.addEventListener("click", function () { emit("selectPage", { navigation: item.navigation }); });
      container.appendChild(button);
    });
    setIcons(container);
  }

  function renderMetric(metric) {
    var button = document.createElement("button");
    button.type = "button";
    button.className = "metric-card tone-" + toneClass(metric.tone);
    button.innerHTML = '<span class="metric-topline"><span class="metric-title"></span><span class="metric-icon" data-symbol="' + metric.symbol + '"></span></span><span class="metric-value"><span class="metric-number"></span>' + (metric.destination ? '<span class="metric-chevron" aria-hidden="true">›</span>' : "") + '</span><span class="metric-subtitle"></span>';
    button.querySelector(".metric-title").textContent = metric.title;
    button.querySelector(".metric-number").textContent = metric.value;
    button.querySelector(".metric-subtitle").textContent = metric.subtitle;
    if (metric.destination) button.addEventListener("click", function () { emit("selectPage", { navigation: metric.destination }); });
    return button;
  }

  function renderServices(rows, actions) {
    var container = document.getElementById("services");
    container.innerHTML = "";
    (rows || []).forEach(function (row) {
      var element = document.createElement(row.destination ? "button" : "div");
      element.className = "service-row tone-" + toneClass(row.tone);
      if (row.destination) { element.type = "button"; element.addEventListener("click", function () { emit("selectPage", { navigation: row.destination }); }); }
      element.innerHTML = '<span class="service-icon" data-symbol="' + row.symbol + '"></span><span class="service-title"></span><span class="status-badge ' + toneClass(row.tone) + '"></span>';
      element.querySelector(".service-title").textContent = row.title;
      element.querySelector(".status-badge").textContent = row.value;
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
        button.addEventListener("click", function () {
          emit(action.command, { navigation: action.destination || null, taskID: action.taskID || null });
        });
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
      row.innerHTML = '<span class="status-badge neutral recent-status"></span><span class="recent-source"></span><span><span class="recent-title"></span><span class="recent-project"></span></span><span class="recent-time"></span><span class="recent-chevron" aria-hidden="true">›</span>';
      row.querySelector(".recent-status").textContent = task.status;
      row.querySelector(".recent-source").textContent = task.source;
      row.querySelector(".recent-title").textContent = task.title;
      row.querySelector(".recent-project").textContent = task.projectName;
      row.querySelector(".recent-time").textContent = task.updatedAt;
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
      element.innerHTML = '<span class="icon" data-symbol="' + notice.symbol + '"></span><div><h4></h4><p></p></div>' + (notice.destination ? '<button type="button" class="link-button">处理 →</button>' : "");
      element.querySelector("h4").textContent = notice.title;
      element.querySelector("p").textContent = notice.message;
      if (notice.destination) element.querySelector("button").addEventListener("click", function () { emit("selectPage", { navigation: notice.destination }); });
      container.appendChild(element);
    });
    setIcons(container);
  }

  function renderState(nextState) {
    state = nextState;
    var shell = document.getElementById("app-shell");
    var loading = document.getElementById("loading-state");
    var overview = document.getElementById("overview-page");
    var placeholder = document.getElementById("placeholder-page");
    var hasOverview = !!(state && state.overview && state.selectedNavigation === "overview");
    loading.hidden = !!state;
    overview.hidden = !hasOverview;
    placeholder.hidden = !state || hasOverview;
    shell.dataset.state = state ? "ready" : "loading";
    if (!state) return;

    renderNavigation(state.navigation, state.selectedNavigation);
    var selectedItem = (state.navigation || []).find(function (item) { return item.navigation === state.selectedNavigation; }) || {};
    document.getElementById("page-title").textContent = hasOverview ? state.overview.title : selectedItem.title || "Codex Bridge";
    document.getElementById("placeholder-title").textContent = selectedItem.title || "等待页面状态";
    var indicator = document.getElementById("connection-indicator");
    indicator.className = "connection-indicator " + toneClass(state.connectionTone);
    document.getElementById("connection-label").textContent = state.connectionLabel;
    document.getElementById("refresh-indicator").classList.toggle("is-visible", !!state.isRefreshing);
    document.querySelector(".refresh-button").classList.toggle("is-refreshing", !!state.isRefreshing);
    if (!hasOverview) return;
    document.getElementById("overview-title").textContent = state.overview.title;
    document.getElementById("overview-subtitle").textContent = state.overview.subtitle;
    var metrics = document.getElementById("metrics");
    metrics.innerHTML = "";
    state.overview.metrics.forEach(function (metric) { metrics.appendChild(renderMetric(metric)); });
    setIcons(metrics);
    renderServices(state.overview.services, state.overview.serviceActions);
    renderRecentTasks(state.overview.recentTasks);
    renderNotices(state.overview.notices);
  }

  document.addEventListener("click", function (event) {
    var action = event.target.closest("[data-action]");
    if (!action) return;
    if (action.dataset.action === "refresh") emit("refresh");
    if (action.dataset.action === "select-page") emit("selectPage", { navigation: action.dataset.page });
    if (action.dataset.action === "toggle-sidebar") document.getElementById("app-shell").classList.toggle("sidebar-collapsed");
  });

  window.CodexBridgeDesktopUI = {
    setState: renderState,
    getState: function () { return state; },
    sendCommand: emit
  };
  if (window.chrome && window.chrome.webview && window.chrome.webview.addEventListener) {
    window.chrome.webview.addEventListener("message", function (event) {
      var incoming = event.data;
      if (typeof incoming === "string") {
        try { incoming = JSON.parse(incoming); } catch (_) { return; }
      }
      if (incoming && typeof incoming === "object") renderState(incoming);
    });
  }
  setIcons(document);
  emit("ready");
}());
