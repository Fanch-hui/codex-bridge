(function (global) {
  "use strict";
  var S = global.CodexBridgeDesktopPageSupport, E = global.CodexBridgeDesktopDSHWorkspaceEditor;
  function create(onAddImage) {
    var page = {}, emit = null, projectID = null, selectedPath = null, active = false, initialized = false;
    var directories = new Map(), expanded = new Set([""]), pending = null, queue = [], ack = null, diffPath = null, timer = null;
    var refreshBatch = null, gitRefreshRequestID = null, gitLoaded = false;
    var sessionID = null, readGeneration = 0, readRetryTimers = new Set(), busyReads = new Map();
    // Automatic reads wait for the host connection instead of failing against a service that is
    // restarting or reconnecting; reads that failed for that reason are re-issued on reconnect.
    var connected = true, unavailableReads = new Map();
    var completedTurns = 0, turnFinished = false;
    var root = S.node("aside", "dsh-workspace-pane"); root.setAttribute("aria-label", "项目文件与变更");
    var selectedTab = "files", tabStorageKey = "codexbridge.dsh.workspace.tab.v1";
    try {
      var savedTab = global.localStorage.getItem(tabStorageKey);
      if (savedTab === "changes" || savedTab === "agents") selectedTab = savedTab;
    } catch (_) {}
    var tabs = S.node("div", "dsh-workspace-tabs"); tabs.setAttribute("role", "tablist");
    tabs.setAttribute("aria-label", "项目工作区"); root.appendChild(tabs);
    var filesPanel = S.node("section", "dsh-workspace-panel"), changesPanel = S.node("section", "dsh-workspace-panel"),
      agentsPanel = S.node("section", "dsh-workspace-panel");
    filesPanel.id = "dsh-workspace-files"; changesPanel.id = "dsh-workspace-changes"; agentsPanel.id = "dsh-workspace-agents";
    [filesPanel, changesPanel, agentsPanel].forEach(function (panel) { panel.setAttribute("role", "tabpanel"); });
    var tabKinds = ["files", "changes", "agents"];
    function selectTab(kind) {
      if (!tabKinds.includes(kind)) kind = "files";
      selectedTab = kind;
      filesPanel.hidden = kind !== "files"; changesPanel.hidden = kind !== "changes"; agentsPanel.hidden = kind !== "agents";
      [filesTab, changesTab, agentsTab].forEach(function (tab, index) {
        var selected = tabKinds[index] === kind;
        tab.setAttribute("aria-selected", String(selected)); tab.tabIndex = selected ? 0 : -1;
      });
      try { global.localStorage.setItem(tabStorageKey, kind); } catch (_) {}
    }
    function tab(title, kind, panel) {
      var control = button(title, function () { selectTab(kind); }, tabs, "small dsh-workspace-tab");
      control.id = panel.id + "-tab"; control.setAttribute("role", "tab");
      control.setAttribute("aria-controls", panel.id); panel.setAttribute("aria-labelledby", control.id);
      control.addEventListener("keydown", function (event) {
        if (!["ArrowLeft", "ArrowRight", "Home", "End"].includes(event.key)) return;
        event.preventDefault();
        var controls = [filesTab, changesTab, agentsTab], index = tabKinds.indexOf(selectedTab);
        var nextIndex = event.key === "Home" ? 0 : event.key === "End" ? controls.length - 1
          : (index + (event.key === "ArrowRight" ? 1 : controls.length - 1)) % controls.length;
        selectTab(tabKinds[nextIndex]); controls[nextIndex].focus();
      });
      return control;
    }
    var filesTab = tab("文件", "files", filesPanel), changesTab = tab("变更", "changes", changesPanel),
      agentsTab = tab("Agent", "agents", agentsPanel);
    var header = S.node("header", "dsh-workspace-heading"); filesPanel.appendChild(header);
    function button(title, action, parent, style) {
      var value = S.button(title, null, {}, null, style || "small"); value.addEventListener("click", action);
      parent.appendChild(value); return value;
    }
    var refreshButton = button("刷新", function () { if (!refreshButton.disabled) refresh(true); }, header);
    function createFeedback(panel) {
      var message = S.node("p", "hint dsh-workspace-message"); message.setAttribute("role", "status"); message.hidden = true;
      var diagnostics = S.node("details", "dsh-workspace-error-details"); diagnostics.hidden = true;
      diagnostics.appendChild(S.node("summary", null, "诊断详情"));
      var diagnosticText = S.node("pre"); diagnostics.appendChild(diagnosticText);
      panel.appendChild(message); panel.appendChild(diagnostics);
      var recovery = button("恢复请求", function () {
        if (!pending || !emit || recovery.disabled) return;
        recovery.disabled = true; message.textContent = "正在确认原请求…"; message.hidden = false;
        ack = null; armRecoveryTimer();
        emit("workbenchWorkspace", pending.payload, pending.requestID);
      }, panel); recovery.hidden = true;
      return { message: message, diagnostics: diagnostics, diagnosticText: diagnosticText, recovery: recovery };
    }
    var feedbacks = { files: createFeedback(filesPanel), changes: createFeedback(changesPanel) };
    var message, diagnostics, diagnosticText, recovery;
    function useFeedback(action) {
      var feedback = ["gitStatus", "gitDiff"].includes(action) ? feedbacks.changes : feedbacks.files;
      message = feedback.message; diagnostics = feedback.diagnostics;
      diagnosticText = feedback.diagnosticText; recovery = feedback.recovery;
    }
    useFeedback("listDirectory");
    var tree = S.node("nav", "dsh-file-tree"); tree.setAttribute("aria-label", "项目目录"); tree.tabIndex = -1; filesPanel.appendChild(tree);
    var editor = E.create(request, closeFile); filesPanel.appendChild(editor.root);
    var gitHeader = S.node("header", "dsh-workspace-heading"); gitHeader.appendChild(S.node("h3", null, "项目当前变更"));
    var refreshChangesButton = button("刷新变更", function () {
      if (refreshChangesButton.disabled) return;
      var command = request("gitStatus", {}); if (command) gitRefreshRequestID = command.requestID;
    }, gitHeader); changesPanel.appendChild(gitHeader);
    var changes = S.node("nav", "dsh-git-changes"); changes.setAttribute("aria-label", "Git 文件变更"); changesPanel.appendChild(changes);
    var diff = S.node("pre", "dsh-git-diff"); diff.setAttribute("aria-label", "Git Diff"); changesPanel.appendChild(diff);
    var agentsEmpty = S.node("p", "hint dsh-workspace-agents-empty", "当前会话暂无调用的 Agent。");
    agentsPanel.appendChild(agentsEmpty);
    var subagentsNode = null;
    function syncSubagents() {
      agentsEmpty.hidden = !!(subagentsNode && !subagentsNode.hidden && subagentsNode.children.length);
    }
    function mountSubagents(node) {
      subagentsNode = node;
      if (node) agentsPanel.appendChild(node);
      syncSubagents();
    }
    function retryableRead(command) {
      return ["listDirectory", "gitStatus"].includes(command.payload.action);
    }
    function shouldShowBusy(command) {
      if (refreshBatch && refreshBatch.has(command.requestID) || gitRefreshRequestID === command.requestID) return true;
      if (command.payload.action === "listDirectory") {
        return !!command.payload.value || !directories.has(command.payload.path || "");
      }
      return !gitLoaded;
    }
    function readKey(command) { return JSON.stringify(command.payload); }
    function invalidateReads() {
      var needsReload = readRetryTimers.size || busyReads.size || unavailableReads.size
        || pending && retryableRead(pending) || queue.some(retryableRead);
      readGeneration++; turnFinished = false; completedTurns = 0; busyReads.clear(); unavailableReads.clear();
      readRetryTimers.forEach(function (retry) { clearTimeout(retry); }); readRetryTimers.clear();
      queue = queue.filter(function (command) { return !retryableRead(command); });
      if (pending && retryableRead(pending)) {
        pending = null; ack = null;
        if (timer) clearTimeout(timer); timer = null;
        recovery.hidden = true;
      }
      refreshBatch = null; gitRefreshRequestID = null;
      if (needsReload) initialized = false;
    }
    function setSession(id) {
      id = id || null;
      if (sessionID === id) return;
      sessionID = id; invalidateReads();
    }
    function retryRead(command, delay) {
      var generation = readGeneration;
      var retry = setTimeout(function () {
        readRetryTimers.delete(retry);
        if (!active || generation !== readGeneration || command.payload.projectID !== projectID) return;
        if (hasRequest(command.payload.action, command.payload.path, command.payload.value)) return;
        var previousID = command.requestID;
        command.requestID = global.CodexBridgeDesktopWorkbenchSubmissions.newRequestID();
        command.generation = generation;
        if (refreshBatch && refreshBatch.delete(previousID)) refreshBatch.add(command.requestID);
        if (gitRefreshRequestID === previousID) gitRefreshRequestID = command.requestID;
        queue.push(command); drain();
      }, delay);
      if (retry && retry.unref) retry.unref();
      readRetryTimers.add(retry);
    }
    function receive(item) {
      if (!active || !item || item.sessionID !== sessionID) return;
      var status = item.type === "status" && item.payload && item.payload.status;
      if (status === "running") turnFinished = false;
      var finished = !turnFinished && (item.type === "turn/end" || status === "idle");
      if (!finished) return;
      turnFinished = true;
      completedTurns++;
      if (!busyReads.size) return;
      var retry = Array.from(busyReads.values()); busyReads.clear();
      retry.forEach(function (command) { command.attempts = 0; command.completedTurns = completedTurns; retryRead(command, 0); });
    }
    root.appendChild(filesPanel); root.appendChild(changesPanel); root.appendChild(agentsPanel); selectTab(selectedTab);
    function requests() { return pending ? [pending].concat(queue) : queue; }
    function hasRequest(action, path, value) {
      return requests().some(function (command) {
        return command.payload.action === action && (path === undefined || command.payload.path === path)
          && (value === undefined || command.payload.value === value);
      });
    }
    function updateRefreshButtons() {
      var directory = requests().some(function (command) {
        return command.payload.action === "listDirectory" && command.payload.path === "" && !command.payload.value;
      }), git = hasRequest("gitStatus");
      refreshButton.disabled = !projectID || directory || git;
      refreshButton.textContent = directory || git ? "刷新中…" : "刷新";
      refreshChangesButton.disabled = !projectID || git;
      refreshChangesButton.textContent = git ? "刷新中…" : "刷新变更";
    }
    function armRecoveryTimer() {
      if (timer) clearTimeout(timer);
      var id = pending && pending.requestID;
      timer = setTimeout(function () {
        if (!pending || pending.requestID !== id) return;
        message.textContent = "操作回执未确认，可恢复原请求。"; message.hidden = false;
        recovery.hidden = false; recovery.disabled = false;
      }, 15000);
      if (timer && timer.unref) timer.unref();
    }
    function drain() {
      updateRefreshButtons();
      // Automatic reads stay queued while the connection is down; user actions still get an answer.
      var next = connected ? (queue.length ? 0 : -1) : queue.findIndex(function (command) { return !retryableRead(command); });
      if (pending || !active || !emit || next < 0) return;
      pending = queue.splice(next, 1)[0];
      if (pending.payload.projectID !== projectID) { pending = null; drain(); return; }
      useFeedback(pending.payload.action);
      ack = null; recovery.hidden = true; recovery.disabled = true;
      message.hidden = true; diagnostics.hidden = true;
      armRecoveryTimer(); updateRefreshButtons();
      emit("workbenchWorkspace", pending.payload, pending.requestID);
    }
    function request(action, payload, requestID) {
      if (!projectID) return null;
      var body = Object.assign({ action: action, projectID: projectID }, payload);
      var existing = requests().find(function (command) {
        return requestID && command.requestID === requestID || !requestID
          && ["listDirectory", "gitStatus", "gitDiff"].includes(action)
          && JSON.stringify(command.payload) === JSON.stringify(body);
      });
      if (existing) return existing;
      var command = { requestID: requestID || global.CodexBridgeDesktopWorkbenchSubmissions.newRequestID(), payload: body,
        generation: readGeneration, attempts: 0, completedTurns: completedTurns };
      queue.push(command); drain(); return command;
    }
    function refresh(manual) {
      if (!projectID) return;
      var directory = request("listDirectory", { path: "", limit: 100 }), git = request("gitStatus", {});
      if (manual) refreshBatch = new Set([directory.requestID, git.requestID]);
      if (selectedPath) request("readFile", { path: selectedPath, offset: 1, limit: 10000 });
      if (diffPath) request("gitDiff", { path: diffPath });
    }
    function finishRefresh(command, failed) {
      if (refreshBatch && refreshBatch.has(command.requestID)) {
        if (failed) refreshBatch = null;
        else {
          refreshBatch.delete(command.requestID);
          if (!refreshBatch.size) { message.textContent = "目录与变更已刷新。"; message.hidden = false; refreshBatch = null; }
        }
      }
      if (gitRefreshRequestID === command.requestID) {
        gitRefreshRequestID = null;
        if (!failed) { message.textContent = "变更已刷新。"; message.hidden = false; }
      }
    }
    function openFile(path) {
      selectedPath = path; editor.select(projectID, path);
      request("readFile", { path: path, offset: 1, limit: 10000 }); renderTree();
    }
    function closeFile() {
      var closedPath = selectedPath;
      selectedPath = null; editor.select(projectID, null);
      queue = queue.filter(function (command) {
        return command.payload.action !== "readFile" || command.payload.path !== closedPath;
      });
      renderTree();
    }
    function directoryRows(path, depth) {
      var directory = directories.get(path);
      if (!directory) return;
      directory.entries.forEach(function (entry) {
        var relative = E.field(entry, "relativePath", "relative_path"), folder = entry.kind === "directory";
        var container = S.node("div", "dsh-file-entry"); tree.appendChild(container);
        var row = button("", function () {
          if (!folder) { openFile(relative); return; }
          if (expanded.has(relative)) expanded.delete(relative);
          else {
            expanded.add(relative);
            if (!directories.has(relative)) request("listDirectory", { path: relative, limit: 100 });
          }
          renderTree();
        }, container, "dsh-file-row" + (relative === selectedPath ? " is-active" : ""));
        row.style.paddingInlineStart = (depth * 12 + 8) + "px"; row.title = relative;
        row.dataset.workspaceFocusKey = "entry:" + relative;
        row.appendChild(S.icon(folder ? "folder.fill" : "doc.text", "dsh-file-icon"));
        row.appendChild(S.node("span", "dsh-file-name", relative.split("/").pop()));
        row.setAttribute("aria-label", relative);
        if (folder) row.setAttribute("aria-expanded", String(expanded.has(relative)));
        else row.setAttribute("aria-current", relative === selectedPath ? "true" : "false");
        if (!folder && /\.(png|jpe?g|webp)$/i.test(relative) && onAddImage) {
          var add = button("", function () {
            var status = feedbacks.files.message;
            if (onAddImage(projectID, relative)) { status.textContent = ""; status.hidden = true; }
            else { status.textContent = "在新会话中选择支持图片的模型后添加。"; status.hidden = false; }
          }, container, "small dsh-file-add-image");
          add.dataset.workspaceFocusKey = "image:" + relative;
          add.appendChild(S.icon("plus")); add.title = "添加到新会话";
          add.setAttribute("aria-label", "添加图片到新会话：" + relative);
        }
        if (folder && expanded.has(relative)) directoryRows(relative, depth + 1);
      });
      if (directory.nextCursor) {
        var more = button("加载更多文件", function () {
          request("listDirectory", { path: path, value: directory.nextCursor, limit: 100 });
          renderTree();
        }, tree);
        more.dataset.workspaceFocusKey = "more:" + path;
        more.disabled = hasRequest("listDirectory", path, directory.nextCursor);
        if (more.disabled) more.textContent = "加载中…";
      }
    }
    function renderTree(fallback) {
      var focused = document.activeElement;
      var focusKey = tree.contains(focused) && focused.dataset.workspaceFocusKey;
      S.clear(tree);
      if (!projectID) tree.appendChild(S.node("p", "hint", "先选择项目。"));
      else if (!directories.has("")) tree.appendChild(S.node("p", "hint", "正在读取目录…"));
      else if (!directories.get("").entries.length) tree.appendChild(S.node("p", "hint", "目录为空。"));
      else directoryRows("", 0);
      if (focusKey) {
        var buttons = Array.from(tree.querySelectorAll("button"));
        var replacement = buttons.find(function (item) { return item.dataset.workspaceFocusKey === focusKey; });
        var moved = false;
        if (!replacement && fallback && fallback.from === focusKey) {
          replacement = buttons.find(function (item) { return item.dataset.workspaceFocusKey === fallback.to; }) || tree;
          moved = true;
        }
        if (replacement) replacement.focus({ preventScroll: !moved });
      }
    }
    function renderGit(git, failed) {
      gitLoaded = !!git;
      S.clear(changes);
      if (!git) {
        changes.appendChild(S.node("p", "hint", !projectID ? "先选择项目。"
          : failed ? "未能读取变更，可点击“刷新变更”重试。" : "正在读取变更…"));
        return;
      }
      var labels = { clean: "工作区干净。", not_git: "此项目不是 Git 仓库。", check_failed: "Git 检查失败，请刷新重试。" };
      if (labels[git.state]) changes.appendChild(S.node("p", "hint", labels[git.state]));
      S.safeArray(git.entries).forEach(function (entry) {
        var row = button("", function () {
          diffPath = entry.relativePath; diff.textContent = "正在读取 Diff…";
          request("gitDiff", { path: diffPath });
        }, changes, "dsh-file-row");
        row.title = entry.originalPath ? entry.originalPath + " → " + entry.relativePath : entry.relativePath;
        row.appendChild(S.node("span", "dsh-file-name", entry.relativePath));
        row.appendChild(S.node("span", "dsh-git-status", (entry.indexStatus || " ") + (entry.worktreeStatus || " ")));
        row.setAttribute("aria-label", entry.relativePath + "，暂存 " + (entry.indexStatus || "无") + "，工作区 " + (entry.worktreeStatus || "无"));
      });
      if (git.truncated) changes.appendChild(S.node("p", "hint", "变更列表已截断。"));
    }
    function acknowledge(state) {
      if (!pending || !state || state.projectID !== projectID || state.lastRequestID !== pending.requestID) return;
      if (ack === state.lastRequestID) return;
      ack = state.lastRequestID;
      if (timer) clearTimeout(timer); timer = null; recovery.hidden = true;
      var command = pending; pending = null;
      if (retryableRead(command) && command.generation !== readGeneration) { drain(); return; }
      if (state.errorCode === "service_unavailable" && retryableRead(command)) {
        command.attempts++;
        if (connected && command.attempts < 4) {
          message.textContent = shouldShowBusy(command) ? "正在重新连接后台服务…" : "";
          message.hidden = !message.textContent; diagnostics.hidden = true;
          retryRead(command, command.attempts * 500); drain(); return;
        }
        unavailableReads.set(readKey(command), command);
      } else if (state.errorCode === "busy" && retryableRead(command)) {
        command.attempts++;
        if (command.attempts < 3) {
          message.textContent = shouldShowBusy(command) ? "正在等待服务空闲…" : "";
          message.hidden = !message.textContent; diagnostics.hidden = true;
          retryRead(command, command.attempts === 1 ? 100 : 250); drain(); return;
        }
        if (command.completedTurns !== completedTurns) {
          command.attempts = 0; command.completedTurns = completedTurns;
          retryRead(command, 0); drain(); return;
        }
        busyReads.set(readKey(command), command);
      } else if (!state.errorMessage && retryableRead(command)) {
        busyReads.delete(readKey(command)); unavailableReads.delete(readKey(command));
      }
      if (state.errorMessage) {
        message.textContent = String(state.errorMessage).split("\n")[0]; message.hidden = false;
        diagnosticText.textContent = state.errorMessage; diagnostics.hidden = false; diagnostics.open = false;
        if (command.payload.action === "listDirectory") renderTree();
        if (command.payload.action === "gitStatus" && !gitLoaded) renderGit(null, true);
      } else {
        message.textContent = ""; message.hidden = true; diagnostics.hidden = true;
        if (command.payload.action === "listDirectory" && state.directory) {
          var directory = state.directory, path = E.field(directory, "relativeDirectory", "relative_directory") || "";
          if (path !== command.payload.path) { drain(); return; }
          var previous = command.payload.value && directories.get(path), incoming = S.safeArray(directory.entries);
          var entries = (previous ? previous.entries : []).concat(incoming);
          var nextCursor = E.field(directory, "nextCursor", "next_cursor"), fallback = null;
          if (previous && !nextCursor) {
            var firstPath = incoming.length && E.field(incoming[0], "relativePath", "relative_path");
            fallback = { from: "more:" + path, to: "entry:" + (firstPath || path) };
          }
          directories.set(path, { entries: entries, nextCursor: nextCursor }); renderTree(fallback);
        }
        if (command.payload.action === "gitStatus") renderGit(state.git);
        if (command.payload.action === "gitDiff" && state.diff && state.diff.relativePath === diffPath) {
          diff.textContent = state.diff.text + (state.diff.truncated ? "\n…Diff 已截断" : "");
        }
      }
      editor.receive(state, command);
      finishRefresh(command, !!state.errorMessage);
      if (command.payload.action === "applyWrite" && state.mutation && state.mutation.status === "applied") request("gitStatus", {});
      drain();
    }
    function resumeUnavailableReads() {
      if (!unavailableReads.size) return;
      var resumed = Array.from(unavailableReads.values()); unavailableReads.clear();
      resumed.forEach(function (command) { command.attempts = 0; retryRead(command, 0); });
    }
    function ensureLoaded() {
      if (!active || !connected || initialized || !projectID) return;
      initialized = true; refresh();
    }
    function update(nextPage, nextEmit, nextConnected) {
      page = nextPage || {}; emit = nextEmit;
      var wasConnected = connected; connected = nextConnected !== false;
      var nextProject = page.selectedProjectID || null;
      if (nextProject !== projectID) {
        invalidateReads();
        projectID = nextProject; selectedPath = null; diffPath = null; pending = null; queue = []; ack = null;
        refreshBatch = null; gitRefreshRequestID = null;
        if (timer) clearTimeout(timer); timer = null; recovery.hidden = true;
        directories.clear(); expanded = new Set([""]); initialized = false;
        editor.select(projectID, null); diff.textContent = "";
        Object.values(feedbacks).forEach(function (feedback) {
          feedback.message.textContent = ""; feedback.message.hidden = true;
          feedback.diagnostics.hidden = true; feedback.recovery.hidden = true;
        });
        renderTree(); renderGit(null);
      }
      acknowledge(page.workspace);
      if (connected && !wasConnected) resumeUnavailableReads();
      ensureLoaded(); drain();
    }
    function setActive(value, nextEmit) {
      value = !!value;
      if (active && !value) invalidateReads();
      active = value; if (nextEmit) emit = nextEmit; root.hidden = !active; ensureLoaded(); drain();
    }
    editor.select(null, null); renderTree(); renderGit(null);
    return { root: root, update: update, setActive: setActive, setSession: setSession, receive: receive,
      selectTab: selectTab, mountSubagents: mountSubagents, syncSubagents: syncSubagents };
  }
  global.CodexBridgeDesktopDSHWorkspace = { create: create };
})(window);
