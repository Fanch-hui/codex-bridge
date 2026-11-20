(function (global) {
  "use strict";
  var S = global.CodexBridgeDesktopPageSupport, T = global.CodexBridgeDesktopEmbeddedDSHTransport;

  function createPager(request, isCurrent, onChange) {
    var version = 0, scope = null, query = "", rows = [], cursor = null, loading = false, error = "", retryCursor = null;
    function valid(ticket) {
      if (ticket !== version) return false;
      if (isCurrent(scope)) return true;
      cancel(); onChange(snapshot()); return false;
    }
    function snapshot() { return { rows: rows.slice(), cursor: cursor, loading: loading, error: error }; }
    function cancel() { version++; scope = null; rows = []; cursor = null; loading = false; error = ""; retryCursor = null; }
    function fetchPage(pageCursor, remaining) {
      var ticket = version;
      if (!valid(ticket) || loading) return Promise.resolve();
      loading = true; error = ""; onChange(snapshot());
      return request(scope, query, pageCursor).then(function (result) {
        if (!valid(ticket)) return;
        result = result || {};
        rows = Array.isArray(result.items) ? result.items.slice(0, 20) : [];
        cursor = result.hasMore && typeof result.cursor === "string" && result.cursor ? result.cursor : null;
        loading = false; retryCursor = null;
        if (!rows.length && cursor && remaining > 0) return fetchPage(cursor, remaining - 1);
        onChange(snapshot());
      }, function (failure) {
        if (!valid(ticket)) return;
        loading = false; retryCursor = pageCursor;
        error = failure && failure.message || "无法读取项目文件。";
        onChange(snapshot());
      });
    }
    function start(nextScope, nextQuery) {
      cancel(); scope = nextScope; query = nextQuery;
      return fetchPage(null, 1);
    }
    function next() { return cursor && !loading ? fetchPage(cursor, 1) : Promise.resolve(); }
    function retry() { return error && !loading ? fetchPage(retryCursor, 0) : Promise.resolve(); }
    return { start: start, next: next, retry: retry, cancel: cancel, snapshot: snapshot };
  }

  // `agents` (optional) is the Agent directory: its entries are listed ahead of the project files.
  function create(input, parent, context, changed, agents) {
    var A = global.CodexBridgeDesktopEmbeddedDSHAgentMentions;
    var root = S.node("div", "dsh-file-mentions"), rows = [], agentRows = [], selected = 0, timer = null, current = null;
    var pager = createPager(function (scope, query, cursor) {
      var params = { projectID: scope.projectID, query: query };
      if (scope.sessionID) params.sessionId = scope.sessionID;
      if (cursor) params.cursor = cursor;
      var key = JSON.stringify([scope.projectID, scope.sessionID, query, cursor]);
      return T.read("mentions." + key, function () {
        return T.call("session.fileReferences", params);
      });
    }, function (scope) {
      var active = context();
      return !!scope && active.connected && active.sessionID === scope.sessionID && active.projectID === scope.projectID;
    }, function () { selected = 0; render(); });
    root.hidden = true; root.setAttribute("role", "listbox"); root.setAttribute("aria-label", "Agent 与项目文件"); parent.appendChild(root);
    if (agents) agents.subscribe(function () { if (current) render(); });
    function hide() {
      if (timer) global.clearTimeout(timer);
      timer = null; pager.cancel(); current = null; rows = []; agentRows = []; root.hidden = true; S.clear(root);
    }
    function match() {
      var before = input.value.slice(0, input.selectionStart), found = /(?:^|\s)@(?:"([^"\n]*)|([^\s"@]*))$/u.exec(before);
      if (!found) return null;
      var query = found[1] === undefined ? found[2] : found[1];
      if (/^\[[^\]]*\]$/.test(query)) return null;
      return { query: query, start: before.length - query.length - (found[1] === undefined ? 1 : 2), end: before.length };
    }
    function chooseAgent(entry) {
      if (!current) return;
      input.setRangeText(A.tokenOf(entry) + " ", current.start, current.end, "end");
      hide(); changed(); input.focus();
    }
    function choose(row) {
      if (!current || !row || typeof row.path !== "string") return;
      var path = row.path;
      if (row.kind === "directory" && !path.endsWith("/")) path += "/";
      var quoted = /\s|"/u.test(path) || /^\[[^\]\n]+\]$/u.test(path), value = quoted
        ? '@"' + path.replace(/"/g, '\\"') + (row.kind === "directory" ? "" : '"') : "@" + path;
      var end = row.kind === "directory" ? "" : " ";
      input.setRangeText(value + end, current.start, current.end, "end");
      hide(); changed(); input.focus();
      if (row.kind === "directory") update();
    }
    function option(label, index, action, className) {
      var button = S.button(label, null, {}, null, "small dsh-file-mention" + (className ? " " + className : ""));
      button.setAttribute("role", "option"); button.setAttribute("aria-selected", String(index === selected));
      button.title = label; button.addEventListener("mousedown", function (event) { event.preventDefault(); });
      button.addEventListener("click", action); root.appendChild(button);
      return button;
    }
    function render() {
      var state = pager.snapshot(), scope = context(); rows = state.rows;
      agentRows = agents && current ? A.filter(agents.list(scope) || [], current.query) : [];
      if (selected >= agentRows.length + rows.length + (state.error || state.cursor && !state.loading ? 1 : 0)) selected = 0;
      S.clear(root);
      agentRows.forEach(function (entry, index) {
        var button = option(entry.label, index, function () { chooseAgent(entry); }, "dsh-agent-mention");
        button.insertBefore(S.icon("person.2"), button.firstChild);
      });
      if (agentRows.length && (rows.length || state.error || state.cursor || state.loading)) {
        var separator = S.node("div", "dsh-file-mention-separator"); separator.setAttribute("role", "separator"); root.appendChild(separator);
      }
      rows.forEach(function (row, index) { option(row.path, agentRows.length + index, function () { choose(row); }); });
      if (state.error) option("重试 · " + state.error, agentRows.length + rows.length, function () { pager.retry(); });
      else if (state.cursor && !state.loading) option("继续查找", agentRows.length + rows.length, function () { pager.next(); });
      if (state.loading) {
        var status = S.node("div", "dsh-file-mention-status", "正在查找文件…");
        status.setAttribute("role", "status"); root.appendChild(status);
      }
      root.hidden = !agentRows.length && !rows.length && !state.cursor && !state.loading && !state.error;
    }
    function update() {
      if (timer) global.clearTimeout(timer);
      var next = match(), scope = context();
      if (!next || !scope.projectID || !scope.connected) { hide(); return; }
      pager.cancel(); current = next; rows = []; selected = 0;
      if (agents) agents.ensure(scope);
      render();
      timer = global.setTimeout(function () { timer = null; pager.start(scope, next.query); }, 150);
    }
    // Backspace right behind a mark removes the whole mark.
    function removeMark() {
      if (!agents || input.selectionStart !== input.selectionEnd) return false;
      var before = input.value.slice(0, input.selectionStart), marks = A.parse(before, agents.list(context()) || []).tokens;
      var last = marks[marks.length - 1];
      if (!last || last.end !== before.length && !(last.end + 1 === before.length && before[last.end] === " ")) return false;
      input.setRangeText("", last.start, before.length, "end");
      hide(); changed(); return true;
    }
    function keydown(event) {
      if (S.isIMEKeyEvent(event)) return false;
      if (event.key === "Backspace" && removeMark()) { event.preventDefault(); return true; }
      if (root.hidden) return false;
      if (event.key === "Escape") { event.preventDefault(); hide(); return true; }
      var state = pager.snapshot(), count = agentRows.length + rows.length + (state.error || state.cursor && !state.loading ? 1 : 0);
      if (!count) return false;
      if (event.key === "ArrowDown" || event.key === "ArrowUp") {
        event.preventDefault(); selected = (selected + (event.key === "ArrowDown" ? 1 : count - 1)) % count; render(); return true;
      }
      if (event.key === "Enter" && !event.shiftKey) {
        event.preventDefault();
        if (selected < agentRows.length) chooseAgent(agentRows[selected]);
        else if (selected < agentRows.length + rows.length) choose(rows[selected - agentRows.length]);
        else if (state.error) pager.retry();
        else pager.next();
        return true;
      }
      return false;
    }
    return { root: root, update: update, hide: hide, keydown: keydown };
  }
  global.CodexBridgeDesktopEmbeddedDSHMentions = { create: create };
  if (typeof module !== "undefined" && module.exports) module.exports = { createPager: createPager };
}(typeof window === "undefined" ? globalThis : window));
