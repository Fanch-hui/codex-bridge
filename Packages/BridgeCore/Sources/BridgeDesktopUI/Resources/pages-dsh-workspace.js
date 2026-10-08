(function (global) {
  "use strict";
  var S = global.CodexBridgeDesktopPageSupport, E = global.CodexBridgeDesktopDSHWorkspaceEditor;
  function create(onAddImage) {
    var page = {}, emit = null, projectID = null, selectedPath = null, active = false, initialized = false;
    var directories = new Map(), expanded = new Set([""]), pending = null, queue = [], ack = null, diffPath = null, timer = null;
    var root = S.node("aside", "dsh-workspace-pane"); root.setAttribute("aria-label", "项目文件与变更");
    var disclosure = S.node("details", "dsh-workspace-disclosure");
    disclosure.open = !(global.matchMedia && global.matchMedia("(max-width: 1100px)").matches);
    disclosure.appendChild(S.node("summary", "dsh-workspace-summary", "文件 / 变更")); root.appendChild(disclosure);
    var header = S.node("header", "dsh-workspace-heading"); disclosure.appendChild(header);
    header.appendChild(S.node("h3", null, "项目文件"));
    function button(title, action, parent, style) {
      var value = S.button(title, null, {}, null, style || "small"); value.addEventListener("click", action);
      parent.appendChild(value); return value;
    }
    button("刷新", refresh, header);
    var message = S.node("p", "hint dsh-workspace-message"); message.setAttribute("role", "status"); disclosure.appendChild(message);
    var diagnostics = S.node("details", "dsh-workspace-error-details"); diagnostics.hidden = true;
    diagnostics.appendChild(S.node("summary", null, "诊断详情"));
    var diagnosticText = S.node("pre"); diagnostics.appendChild(diagnosticText); disclosure.appendChild(diagnostics);
    var recovery = button("恢复请求", function () {
      if (!pending || !emit) return;
      ack = null;
      emit("workbenchWorkspace", pending.payload, pending.requestID);
    }, disclosure); recovery.hidden = true;
    var tree = S.node("nav", "dsh-file-tree"); tree.setAttribute("aria-label", "项目目录"); disclosure.appendChild(tree);
    var editor = E.create(request, closeFile); disclosure.appendChild(editor.root);
    var gitHeader = S.node("header", "dsh-workspace-heading"); gitHeader.appendChild(S.node("h3", null, "项目当前变更"));
    button("刷新变更", function () { request("gitStatus", {}); }, gitHeader); disclosure.appendChild(gitHeader);
    var changes = S.node("nav", "dsh-git-changes"); changes.setAttribute("aria-label", "Git 文件变更"); disclosure.appendChild(changes);
    var diff = S.node("pre", "dsh-git-diff"); diff.setAttribute("aria-label", "Git Diff"); disclosure.appendChild(diff);
    function drain() {
      if (pending || !active || !emit || !queue.length) return;
      pending = queue.shift();
      if (pending.payload.projectID !== projectID) { pending = null; drain(); return; }
      ack = null; recovery.hidden = true;
      message.hidden = true; diagnostics.hidden = true;
      timer = setTimeout(function () {
        if (!pending) return;
        message.textContent = "操作回执未确认，可恢复原请求。"; message.hidden = false; recovery.hidden = false;
      }, 15000);
      if (timer && timer.unref) timer.unref();
      emit("workbenchWorkspace", pending.payload, pending.requestID);
    }
    function request(action, payload, requestID) {
      if (!projectID) return null;
      var command = { requestID: requestID || global.CodexBridgeDesktopWorkbenchSubmissions.newRequestID(),
        payload: Object.assign({ action: action, projectID: projectID }, payload) };
      queue.push(command); drain(); return command;
    }
    function refresh() {
      if (!projectID) return;
      request("listDirectory", { path: "", limit: 100 }); request("gitStatus", {});
      if (selectedPath) request("readFile", { path: selectedPath, offset: 1, limit: 10000 });
      if (diffPath) request("gitDiff", { path: diffPath });
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
        row.appendChild(S.icon(folder ? "folder.fill" : "doc.text", "dsh-file-icon"));
        row.appendChild(S.node("span", "dsh-file-name", relative.split("/").pop()));
        row.setAttribute("aria-label", relative);
        if (folder) row.setAttribute("aria-expanded", String(expanded.has(relative)));
        else row.setAttribute("aria-current", relative === selectedPath ? "true" : "false");
        if (!folder && /\.(png|jpe?g|webp)$/i.test(relative) && onAddImage) {
          var add = button("", function () {
            if (onAddImage(projectID, relative)) { message.textContent = ""; message.hidden = true; }
            else { message.textContent = "在新会话中选择支持图片的模型后添加。"; message.hidden = false; }
          }, container, "small dsh-file-add-image");
          add.appendChild(S.icon("plus")); add.title = "添加到新会话";
          add.setAttribute("aria-label", "添加图片到新会话：" + relative);
        }
        if (folder && expanded.has(relative)) directoryRows(relative, depth + 1);
      });
      if (directory.nextCursor) button("加载更多文件", function () {
        request("listDirectory", { path: path, value: directory.nextCursor, limit: 100 });
      }, tree);
    }
    function renderTree() {
      S.clear(tree);
      if (!projectID) tree.appendChild(S.node("p", "hint", "先选择项目。"));
      else if (!directories.has("")) tree.appendChild(S.node("p", "hint", "正在读取目录…"));
      else if (!directories.get("").entries.length) tree.appendChild(S.node("p", "hint", "目录为空。"));
      else directoryRows("", 0);
    }
    function renderGit(git) {
      S.clear(changes);
      if (!git) { changes.appendChild(S.node("p", "hint", projectID ? "正在读取变更…" : "先选择项目。")); return; }
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
      if (state.errorMessage) {
        message.textContent = String(state.errorMessage).split("\n")[0]; message.hidden = false;
        diagnosticText.textContent = state.errorMessage; diagnostics.hidden = false; diagnostics.open = false;
      } else {
        message.textContent = ""; message.hidden = true; diagnostics.hidden = true;
        if (command.payload.action === "listDirectory" && state.directory) {
          var directory = state.directory, path = E.field(directory, "relativeDirectory", "relative_directory") || "";
          if (path !== command.payload.path) { drain(); return; }
          var previous = command.payload.value && directories.get(path);
          var entries = (previous ? previous.entries : []).concat(S.safeArray(directory.entries));
          directories.set(path, { entries: entries, nextCursor: E.field(directory, "nextCursor", "next_cursor") }); renderTree();
        }
        if (command.payload.action === "gitStatus") renderGit(state.git);
        if (command.payload.action === "gitDiff" && state.diff && state.diff.relativePath === diffPath) {
          diff.textContent = state.diff.text + (state.diff.truncated ? "\n…Diff 已截断" : "");
        }
      }
      editor.receive(state, command);
      if (command.payload.action === "applyWrite" && state.mutation && state.mutation.status === "applied") request("gitStatus", {});
      drain();
    }
    function ensureLoaded() {
      if (!active || initialized || !projectID) return;
      initialized = true; refresh();
    }
    function update(nextPage, nextEmit) {
      page = nextPage || {}; emit = nextEmit;
      var nextProject = page.selectedProjectID || null;
      if (nextProject !== projectID) {
        projectID = nextProject; selectedPath = null; diffPath = null; pending = null; queue = []; ack = null;
        if (timer) clearTimeout(timer); timer = null; recovery.hidden = true;
        directories.clear(); expanded = new Set([""]); initialized = false;
        editor.select(projectID, null); diff.textContent = ""; message.textContent = ""; message.hidden = true; diagnostics.hidden = true;
        renderTree(); renderGit(null);
      }
      acknowledge(page.workspace); ensureLoaded(); drain();
    }
    function setActive(value, nextEmit) { active = !!value; if (nextEmit) emit = nextEmit; root.hidden = !active; ensureLoaded(); drain(); }
    editor.select(null, null); renderTree(); renderGit(null);
    return { root: root, update: update, setActive: setActive };
  }
  global.CodexBridgeDesktopDSHWorkspace = { create: create };
})(window);
