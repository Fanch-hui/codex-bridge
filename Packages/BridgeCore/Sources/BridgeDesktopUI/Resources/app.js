(function () {
  "use strict";

  var state = null;
  var stateRevision = null;
  var fullStateRequested = false;
  var requestSequence = 0;
  var navigationNodes = new Map();
  var iconPaths = window.CodexBridgeDesktopIcons;
  if (new URLSearchParams(window.location && window.location.search || "").get("surface") === "preferences") {
    document.documentElement.dataset.surface = "preferences";
  }

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
    } else if (root.dataset.platform !== "windows" && root.dataset.platform !== "linux") {
      root.removeAttribute("data-platform");
    }
  }

  function renderFeedback(feedback) {
    if (window.CodexBridgeDesktopFeedback) {
      window.CodexBridgeDesktopFeedback.render(feedback, emit);
    }
  }

  function emit(command, payload, requestID) {
    var prefix = document.documentElement.dataset.surface === "preferences" ? "desktop-preferences-ui-" : "desktop-ui-";
    var envelope = { version: 1, requestID: requestID || prefix + (++requestSequence), command: command, payload: payload || {} };
    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.bridgeDesktopUI) {
      window.webkit.messageHandlers.bridgeDesktopUI.postMessage(envelope);
    }
    if (window.chrome && window.chrome.webview && window.chrome.webview.postMessage) {
      window.chrome.webview.postMessage(envelope);
    }
    window.dispatchEvent(new CustomEvent("codex-bridge-command", { detail: envelope }));
    return envelope.requestID;
  }

  function workbenchMode() {
    var workbench = window.CodexBridgeDesktopDSHWorkbench;
    return workbench && workbench.mode ? workbench.mode() : "dsh";
  }

  function navigate(destination) {
    var workbench = window.CodexBridgeDesktopDSHWorkbench;
    if (destination === "development" && workbench && workbench.showDevelopment) {
      if (workbench.showDevelopment() === false) emit("selectPage", { navigation: "workbench" });
    } else if (destination === "collaboration" && workbench && workbench.openCollaboration) {
      if (workbench.openCollaboration() === false) emit("selectPage", { navigation: "workbench" });
    } else if (destination === "settings") {
      emit("openSettings");
    } else {
      emit("selectPage", { navigation: destination });
    }
    refreshNavigation();
  }

  function renderNavigation(items, selected) {
    var primary = document.getElementById("navigation");
    var secondary = document.getElementById("secondary-navigation");
    var itemByID = new Map((items || []).map(function (item) { return [item.navigation, item]; }));
    var entries = [
      { key: "development", page: "workbench", title: "工作台", symbol: "sparkles" },
      { key: "collaboration", page: "workbench", title: "网页工作台", symbol: "person.2" },
      { key: "projects", page: "projects", title: "项目", symbol: "folder.fill" },
      { key: "overview", page: "overview", title: "动态", symbol: "list.bullet.rectangle" },
      { key: "connections", page: "connections", title: "连接", symbol: "link", secondary: true },
      { key: "settings", page: "settings", title: "设置", symbol: "gearshape", secondary: true }
    ];
    var active = new Set();
    var positions = { primary: 0, secondary: 0 };
    entries.forEach(function (entry) {
      var source = itemByID.get(entry.page);
      if (!source) return;
      var container = entry.secondary ? secondary : primary;
      var positionKey = entry.secondary ? "secondary" : "primary";
      var index = positions[positionKey]++;
      active.add(entry.key);
      var navNode = navigationNodes.get(entry.key);
      var button = navNode && (entry.key === "development" ? navNode.firstChild : navNode);
      if (!button) {
        button = document.createElement("button"); button.type = "button";
        button.appendChild(iconElement(entry.symbol, "icon"));
        button.appendChild(elementWithText("span", "nav-title", entry.title));
        button.appendChild(elementWithText("span", "nav-badge", ""));
        button.addEventListener("click", function () { navigate(entry.key); });
        navNode = button;
        if (entry.key === "development") {
          navNode = document.createElement("div"); navNode.className = "nav-item-with-help";
          navNode.appendChild(button);
          navNode.appendChild(window.CodexBridgeDesktopPageSupport.helpTooltip("工作台说明", "（基于DeepSeek harness开发）"));
        }
        navigationNodes.set(entry.key, navNode);
        setIcons(button);
      }
      var badgeValue = entry.key === "development" ? null : source.badge;
      button.title = entry.title;
      button.setAttribute("aria-label", entry.title + (badgeValue == null ? "" : "，" + badgeValue));
      var isSelected = selected === entry.page;
      if (entry.page === "workbench") {
        isSelected = isSelected && (entry.key === "development" ? workbenchMode() === "dsh" : workbenchMode() !== "dsh");
      } else if (entry.key === "settings" && selected === "logs") {
        isSelected = true;
      }
      button.className = "nav-item" + (isSelected ? " is-selected" : "");
      button.setAttribute("aria-current", isSelected ? "page" : "false");
      var badge = button.querySelector(".nav-badge");
      badge.hidden = badgeValue == null; badge.textContent = badgeValue == null ? "" : badgeValue;
      if (container && container.children[index] !== navNode) container.insertBefore(navNode, container.children[index] || null);
    });
    navigationNodes.forEach(function (node, key) {
      if (!active.has(key)) { node.remove(); navigationNodes.delete(key); }
    });
  }

  function refreshNavigation() {
    if (!state) return;
    renderNavigation(state.navigation, state.selectedNavigation);
    var pageTitle = document.getElementById("page-title");
    if (state.selectedNavigation === "workbench") {
      pageTitle.textContent = workbenchMode() === "dsh" ? "工作台" : "网页工作台";
      pageTitle.title = pageTitle.textContent;
      var workbenchPage = document.getElementById("workbench-page");
      if (workbenchPage) workbenchPage.setAttribute("aria-label", pageTitle.textContent);
    }
    var outsideWorkbench = state.selectedNavigation !== "workbench";
    ["workspace-navigator", "workspace-toolbar-context", "workspace-toolbar-actions"].forEach(function (id) {
      var node = document.getElementById(id);
      if (node) node.hidden = outsideWorkbench;
    });
    document.getElementById("app-shell").dataset.workbenchMode = workbenchMode();
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

  function renderState(nextState, revision) {
    state = nextState;
    if (Number.isInteger(revision)) stateRevision = revision;
    else stateRevision = null;
    applyHostContext(state && state.hostContext);
    var shell = document.getElementById("app-shell");
    var loading = document.getElementById("loading-state");
    loading.hidden = !!state;
    var newConvButton = document.querySelector(".new-conversation-button");
    if (newConvButton) newConvButton.disabled = !state;
    shell.dataset.state = state ? "ready" : "loading";
    if (!state) {
      ["workspace-navigator", "workspace-toolbar-context", "workspace-toolbar-actions"].forEach(function (id) {
        var node = document.getElementById(id);
        if (node) node.hidden = true;
      });
      renderFeedback(null);
      globalPages(null, emit);
      return;
    }
    var selectedItem = (state.navigation || []).find(function (item) { return item.navigation === state.selectedNavigation; }) || {};
    var pageState = state[state.selectedNavigation];
    var pageTitle = document.getElementById("page-title");
    pageTitle.textContent = state.selectedNavigation === "overview"
      ? "动态" : pageState && pageState.header ? pageState.header.title : selectedItem.title || "Codex Bridge";
    pageTitle.title = pageTitle.textContent;
    var indicator = document.getElementById("connection-indicator");
    indicator.className = "connection-indicator " + toneClass(state.connectionTone);
    indicator.title = state.connectionLabel;
    indicator.setAttribute("aria-label", state.connectionLabel);
    var connectionLabel = document.getElementById("connection-label");
    connectionLabel.textContent = state.connectionLabel;
    connectionLabel.hidden = toneClass(state.connectionTone) === "success";
    document.getElementById("refresh-indicator").classList.toggle("is-visible", !!state.isRefreshing);
    document.querySelector(".refresh-button").classList.toggle("is-refreshing", !!state.isRefreshing);
    document.querySelector(".refresh-button").disabled = !!state.isRefreshing;
    renderFeedback(state.feedback);
    if (window.CodexBridgeDesktopAppUpdate && window.CodexBridgeDesktopAppUpdate.renderSidebar) {
      window.CodexBridgeDesktopAppUpdate.renderSidebar(state.appUpdate, emit);
    }
    if (state.selectedNavigation === "overview" && window.CodexBridgeDesktopOverviewPage) {
      window.CodexBridgeDesktopOverviewPage.render(state.overview, state.appUpdate, emit);
    }
    globalPages(state, emit);
    refreshNavigation();
    if (state.selectedNavigation !== "workbench" && window.CodexBridgeDesktopStartup) {
      window.CodexBridgeDesktopStartup.update({ status: "ready" });
    }
  }

  function isStatePatch(value) {
    return !!value && typeof value === "object"
      && value.type === "statePatch"
      && Number.isInteger(value.nextRevision)
      && (value.baseRevision == null || Number.isInteger(value.baseRevision))
      && Array.isArray(value.changes);
  }

  function requestFullState() {
    if (fullStateRequested) return;
    fullStateRequested = true;
    emit("requestStateResync");
  }

  function upsertRows(rows, updates, removedIDs, idKey) {
    var result = Array.isArray(rows) ? rows.slice() : [];
    var index = new Map(result.map(function (row, index) {
      return [row && row[idKey] != null ? String(row[idKey]) : "missing-" + index, index];
    }));
    (Array.isArray(updates) ? updates : []).forEach(function (row) {
      if (!row || row[idKey] == null) return;
      var key = String(row[idKey]);
      var existing = index.get(key);
      if (existing === undefined) {
        index.set(key, result.length);
        result.push(row);
      } else {
        result[existing] = row;
      }
    });
    var removed = new Set((Array.isArray(removedIDs) ? removedIDs : []).map(String));
    return result.filter(function (row) {
      return !removed.has(String(row && row[idKey]));
    });
  }

  function applyConversationChange(workbench, change) {
    if (!workbench || !workbench.selectedTask || !change
      || change.taskID !== workbench.selectedTask.taskID
      || (change.conversationMode !== "replace" && change.conversationMode !== "upsert")
      || !Array.isArray(change.entries) || !Array.isArray(change.removedIDs)) return false;
    var task = Object.assign({}, workbench.selectedTask);
    var entries = Array.isArray(task.conversation) ? task.conversation : [];
    if (change.conversationMode === "replace") {
      entries = Array.isArray(change.entries) ? change.entries.slice() : [];
      var removed = new Set(change.removedIDs.map(String));
      entries = entries.filter(function (entry) { return !removed.has(String(entry && entry.id)); });
    } else {
      entries = upsertRows(entries, change.entries, change.removedIDs, "id");
    }
    task.conversation = entries;
    task.conversationState = change.conversationState || null;
    workbench.selectedTask = task;
    return true;
  }

  function applyStateChanges(base, changes) {
    var next = Object.assign({}, base);
    var workbench = base && base.workbench
      ? Object.assign({}, base.workbench) : null;
    var valid = true;
    (Array.isArray(changes) ? changes : []).forEach(function (change) {
      if (!change || !change.kind) { valid = false; return; }
      if (change.kind === "overview") {
        next.overview = change.overview || null;
      } else if (change.kind === "connection") {
        next.connections = change.connections || null;
      } else if (change.kind === "projects") {
        next.projects = change.projects || null;
      } else if (change.kind === "logs") {
        next.logs = change.logs || null;
      } else if (change.kind === "appUpdate") {
        next.appUpdate = change.appUpdate || null;
      } else if (!workbench) {
        // Workbench-scoped kinds need a workbench on the page; an empty
        // change list or a page-domain change applies without one.
        valid = false;
      } else if (change.kind === "conversation") {
        valid = applyConversationChange(workbench, change) && valid;
      } else if (change.kind === "taskRows") {
        if ((change.collectionMode !== "replace" && change.collectionMode !== "upsert")
          || !Array.isArray(change.taskRows) || !Array.isArray(change.removedIDs)) {
          valid = false;
        } else {
          workbench.tasks = change.collectionMode === "replace"
            ? change.taskRows.slice()
            : upsertRows(workbench.tasks, change.taskRows, change.removedIDs, "taskID");
        }
      } else if (change.kind === "paneTasks") {
        if ((change.collectionMode !== "replace" && change.collectionMode !== "upsert")
          || !Array.isArray(change.paneTasks) || !Array.isArray(change.removedIDs)) {
          valid = false;
        } else {
          workbench.paneTasks = change.collectionMode === "replace"
            ? change.paneTasks.slice()
            : upsertRows(workbench.paneTasks, change.paneTasks, change.removedIDs, "taskID");
        }
      } else if (change.kind === "approvals") {
        if (!Array.isArray(change.approvalRows)) valid = false;
        else workbench.approvals = change.approvalRows.slice();
      } else if (change.kind === "embeddedDSHReceipts") {
        if (!Array.isArray(change.embeddedDSHReceipts)) valid = false;
        else workbench.embeddedDSHReceipts = change.embeddedDSHReceipts.slice();
      } else if (change.kind === "selectedTask" && change.selectedTask) {
        workbench.selectedTask = change.selectedTask;
        workbench.selectedTaskID = change.taskID || change.selectedTask.taskID || null;
      } else if (change.kind === "browser" && change.browser) {
        workbench.browser = change.browser;
      } else {
        valid = false;
      }
    });
    if (!valid) return null;
    if (workbench) next.workbench = workbench;
    return next;
  }

  function applyStatePatch(envelope) {
    var nextRevision = envelope.nextRevision;
    var hasState = envelope.state !== null && envelope.state !== undefined;
    var hasBase = Number.isInteger(envelope.baseRevision);
    if (hasState && envelope.baseRevision == null && typeof envelope.state === "object") {
      fullStateRequested = false;
      renderState(envelope.state, nextRevision);
      return true;
    }
    if (hasState || !hasBase) {
      requestFullState();
      return false;
    }
    if (!Number.isInteger(nextRevision) || !Number.isInteger(envelope.baseRevision)
      || state === null || stateRevision !== envelope.baseRevision
      || nextRevision !== envelope.baseRevision + 1) {
      requestFullState();
      return false;
    }
    var next = applyStateChanges(state, envelope.changes);
    if (!next) {
      requestFullState();
      return false;
    }
    renderState(next, nextRevision);
    fullStateRequested = false;
    return true;
  }

  function receiveState(value) {
    if (isStatePatch(value)) {
      applyStatePatch(value);
      return;
    }
    fullStateRequested = false;
    renderState(value);
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
    if (action.dataset.action === "new-conversation") window.CodexBridgeDesktopDSHWorkbench.openConversation();
    if (action.dataset.action === "refresh") emit("refresh");
    if (action.dataset.action === "select-page") emit("selectPage", { navigation: action.dataset.page });
  });
  document.addEventListener("contextmenu", function (event) {
    if (document.documentElement.dataset.platform === "windows") {
      event.preventDefault();
    }
  });
  document.addEventListener("keydown", function (event) {
    var platform = document.documentElement.dataset.platform;
    if (document.documentElement.dataset.surface === "preferences"
      || !state || event.defaultPrevented || event.repeat || event.altKey || event.shiftKey
      || !event.ctrlKey || platform !== "windows" && platform !== "linux"
      || document.querySelector("dialog[open]")) return;
    var key = event.key.toLowerCase();
    if (key === "n") {
      event.preventDefault(); window.CodexBridgeDesktopDSHWorkbench.openConversation();
    } else if (key === "o") {
      event.preventDefault(); emit("registerProject");
    } else if (key === ",") {
      event.preventDefault(); emit("openSettings");
    }
  });
  window.addEventListener("resize", function () {
    if (state && state.selectedNavigation === "workbench" && window.CodexBridgeDesktopPages) window.CodexBridgeDesktopPages.measureBrowserViewport(emit);
  });
  window.addEventListener("codex-bridge-workbench-mode-changed", refreshNavigation);
  var overlayObservers = [];
  function observeOverlayHeight(element, property) {
    if (!element || typeof window.ResizeObserver !== "function") return;
    var observer = new window.ResizeObserver(function () {
      document.documentElement.style.setProperty(property, Math.ceil(element.getBoundingClientRect().height) + "px");
    });
    observer.observe(element);
    overlayObservers.push(observer);
  }
  observeOverlayHeight(document.querySelector(".toolbar"), "--app-toolbar-height");
  observeOverlayHeight(document.getElementById("workbench-inspector-footer"), "--workbench-footer-height");
  var contentScroller = document.querySelector(".content-scroll");
  var scrollViewportFrame = 0;
  if (contentScroller) {
    contentScroller.addEventListener("scroll", function () {
      if (scrollViewportFrame || !state || state.selectedNavigation !== "workbench" || !window.CodexBridgeDesktopPages) return;
      scrollViewportFrame = window.requestAnimationFrame(function () {
        scrollViewportFrame = 0;
        window.CodexBridgeDesktopPages.measureBrowserViewport(emit);
      });
    }, { passive: true });
  }

  window.CodexBridgeDesktopUI = {
    setState: receiveState,
    applyStatePatch: applyStatePatch,
    getState: function () { return state; },
    getStateRevision: function () { return stateRevision; },
    sendCommand: emit
  };
  if (window.CodexBridgeDesktopStartup) {
    window.CodexBridgeDesktopStartup.update({ status: "loading", retry: function () { emit("refresh"); } });
  }
  if (window.chrome && window.chrome.webview && window.chrome.webview.addEventListener) {
    window.chrome.webview.addEventListener("message", function (event) {
      var incoming = event.data;
      if (typeof incoming === "string") { try { incoming = JSON.parse(incoming); } catch (_) { return; } }
      if (incoming && typeof incoming === "object") receiveState(incoming);
    });
  }
  setIcons(document);
  emit("ready");
}());
