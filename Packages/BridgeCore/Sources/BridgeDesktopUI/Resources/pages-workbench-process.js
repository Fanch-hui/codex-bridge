(function (global) {
  "use strict";
  var S = global.CodexBridgeDesktopPageSupport;
  var C = global.CodexBridgeDesktopWorkbenchConversation;
  var expanded = new Map();

  function entries(values, page) {
    if (!page.selectedTask || page.selectedTask.isTerminal !== true) return values;
    var result = [], turn = [];
    function finish() {
      if (!turn.length) return;
      var finalIndex = -1;
      turn.forEach(function (entry, index) {
        if (entry.kind !== "reasoning" && entry.kind !== "tool_call") finalIndex = index;
      });
      var process = turn.filter(function (_, index) { return index !== finalIndex; });
      if (process.length) result.push({
        id: "process:" + String(turn[0].id), kind: "process", processEntries: process
      });
      if (finalIndex >= 0) result.push(turn[finalIndex]);
      turn = [];
    }
    values.forEach(function (entry) {
      if (entry.role === "用户") { finish(); result.push(entry); }
      else turn.push(entry);
    });
    finish();
    return result;
  }

  function create(entry, context) {
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
    item.__processEntries = entry.processEntries;
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
      body.appendChild(entry.kind === "reasoning" || entry.kind === "tool_call"
        ? C.createDisclosure(entry, item.__processContext) : C.createMessage(entry));
    });
    item.appendChild(body);
  }

  global.CodexBridgeDesktopWorkbenchProcess = { entries: entries, create: create, update: update };
}(window));
