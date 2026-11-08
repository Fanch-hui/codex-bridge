(function (global) {
  "use strict";
  var S = global.CodexBridgeDesktopPageSupport;
  var C = global.CodexBridgeDesktopWorkbenchConversation;
  var expanded = new Map();

  function text(entry) { return String(entry && entry.text || "").trim(); }
  // Service records mark Agent replies as kind "agent"; other sources use "message".
  function isReply(entry) { return entry.kind === "message" || entry.kind === "agent" || !entry.kind; }

  // Finished turns fold their reasoning and tool steps; replies stay visible. While the
  // selected task runs, only its latest turn stays expanded so progress remains visible.
  // Providers can stream a reply and then report the same reply again; keep one copy.
  // A failed run's raw error is shown in the failure note, not as the turn's answer.
  function cleaned(values, detail) {
    var failed = !!(detail.failureReason || detail.failureCode);
    var errors = failed ? [detail.resultSummary, detail.failureDiagnostic].map(function (value) {
      return String(value || "").trim();
    }).filter(Boolean) : [];
    var lastUser = -1;
    values.forEach(function (entry, index) { if (entry.role === "用户") lastUser = index; });
    var previous = null;
    return values.filter(function (entry, index) {
      if (entry.role === "用户") { previous = null; return true; }
      if (!isReply(entry)) { previous = null; return true; }
      var value = text(entry);
      if (index > lastUser && errors.indexOf(value) >= 0) return false;
      if (previous !== null && value && value === previous && entry.isFinal !== false) return false;
      previous = value;
      return true;
    });
  }

  function entries(values, page) {
    if (!page.selectedTask) return values;
    values = cleaned(values, page.selectedTask);
    var running = page.selectedTask.isTerminal !== true;
    var result = [], turn = [];
    function finish(live) {
      if (!turn.length) return;
      if (live) { result.push.apply(result, turn); turn = []; return; }
      var finalIndex = -1;
      turn.forEach(function (entry, index) { if (isReply(entry)) finalIndex = index; });
      var answer = finalIndex >= 0 ? text(turn[finalIndex]) : "";
      // Only consecutive reasoning and tool steps fold; replies between them stay visible.
      // Providers may report the closing answer twice; the earlier copy adds nothing.
      var run = [];
      function flushRun() {
        if (run.length) result.push({ id: "process:" + String(run[0].id), kind: "process", processEntries: run });
        run = [];
      }
      turn.forEach(function (entry, index) {
        if (entry.kind === "reasoning" || entry.kind === "tool_call") { run.push(entry); return; }
        flushRun();
        if (!isReply(entry) || index === finalIndex || !answer || text(entry) !== answer) result.push(entry);
      });
      flushRun();
      turn = [];
    }
    values.forEach(function (entry) {
      if (entry.role === "用户") { finish(false); result.push(entry); }
      else turn.push(entry);
    });
    finish(running);
    return result;
  }

  function create(entry, context) {
    var upstream = global.CodexBridgeDesktopDSHConversationView;
    if (upstream) return upstream.create(entry, context, entry.onOpenContent);
    var item = S.node("details", "conversation-process");
    item.__processContext = context;
    item.__processKey = JSON.stringify([context, entry.id]);
    item.open = expanded.get(item.__processKey) === true;
    item.__heading = S.node("summary", "entry-heading disclosure-summary");
    item.appendChild(item.__heading);
    item.addEventListener("toggle", function () {
      expanded.set(item.__processKey, !!item.open);
      renderBody(item);
    });
    update(item, entry);
    return item;
  }

  function update(item, entry) {
    if (item.__dshHost) return global.CodexBridgeDesktopDSHConversationView.update(item, entry, item.__dshContext, entry.onOpenContent);
    item.__processEntries = entry.processEntries;
    item.__onRenderChild = entry.onRenderChild;
    item.__heading.textContent = "执行过程（" + entry.processEntries.length + " 条）";
    if (item.__body) { item.__body.remove(); item.__body = null; }
    renderBody(item);
  }

  function renderBody(item) {
    if (!item.open) {
      if (item.__body) { item.__body.remove(); item.__body = null; }
      return;
    }
    if (item.__body) return;
    var body = item.__body = S.node("div", "conversation-process-body conversation-list");
    item.__processEntries.forEach(function (entry) {
      var child = entry.kind === "reasoning" || entry.kind === "tool_call"
        ? C.createDisclosure(entry, item.__processContext) : C.createMessage(entry);
      if (typeof item.__onRenderChild === "function") item.__onRenderChild(child, entry);
      body.appendChild(child);
    });
    item.appendChild(body);
  }

  global.CodexBridgeDesktopWorkbenchProcess = { entries: entries, create: create, update: update };
}(window));
