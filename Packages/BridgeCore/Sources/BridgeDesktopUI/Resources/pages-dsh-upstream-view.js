(function (global) {
  "use strict";
  var S = global.CodexBridgeDesktopPageSupport;
  var pending = new Set();
  var scriptReady = !!global.CodexBridgeDesktopDSHConversationComponents, styleReady = false;
  var attempt = 0, script = null, stylesheet = null, alert = null;

  function reportLoadFailure() {
    if (alert) return;
    alert = S.node("div", "dsh-upstream-load-error");
    alert.setAttribute("role", "alert");
    alert.appendChild(S.node("span", "", "会话显示资源加载失败。"));
    var retry = S.button("重试", null, null, null, "small");
    retry.addEventListener("click", load);
    alert.appendChild(retry); global.document.body.appendChild(alert);
  }

  function paintPending() {
    if (!scriptReady || !styleReady) return;
    if (alert) { alert.remove(); alert = null; }
    Array.from(pending).forEach(paint);
  }

  function load() {
    var generation = ++attempt;
    if (alert) { alert.remove(); alert = null; }
    if (!styleReady) {
      if (stylesheet) stylesheet.remove();
      stylesheet = global.document.createElement("link");
      stylesheet.rel = "stylesheet"; stylesheet.href = "dsh-conversation-upstream.css";
      stylesheet.addEventListener("load", function () {
        if (generation !== attempt) return;
        styleReady = true; paintPending();
      });
      stylesheet.addEventListener("error", function () { if (generation === attempt) reportLoadFailure(); });
      global.document.head.appendChild(stylesheet);
    }
    if (!scriptReady) {
      if (script) script.remove();
      script = global.document.createElement("script");
      script.src = "dsh-conversation-upstream.js"; script.async = true;
      script.addEventListener("load", function () {
        if (generation !== attempt) return;
        scriptReady = !!global.CodexBridgeDesktopDSHConversationComponents;
        if (scriptReady) paintPending(); else reportLoadFailure();
      });
      script.addEventListener("error", function () { if (generation === attempt) reportLoadFailure(); });
      global.document.head.appendChild(script);
    }
    paintPending();
  }

  function paint(item) {
    var components = global.CodexBridgeDesktopDSHConversationComponents;
    if (!components || !scriptReady || !styleReady) {
      pending.add(item);
      var value = item.__dshEntry;
      item.__dshHost.textContent = value.kind === "message" ? value.text || "" : value.displayTitle || value.toolName || "";
      if (attempt === 0) load();
      return;
    }
    pending.delete(item);
    components.render(item.__dshHost, item.__dshEntry, item.__dshOpen, item.__dshContext);
    if (item.__dshRevealPending) { item.__dshRevealPending = false; components.reveal(item.__dshHost); }
  }

  function create(entry, context, openContent) {
    var item = S.node("article", "conversation-entry dsh-upstream-entry");
    item.__dshHost = S.node("div", "dsh-upstream-host");
    item.__dshOpen = function (ref) { if (item.__dshOpenContent) item.__dshOpenContent(ref); };
    item.appendChild(item.__dshHost);
    update(item, entry, context, openContent);
    return item;
  }

  function sameEntry(previous, entry) {
    if (!previous || !entry) return false;
    var fields = ["id", "kind", "role", "text", "isFinal", "running", "toolName", "toolArguments",
      "jobDetails", "displayTitle", "displayStatus", "toolStatus", "deliveryState", "deliveryMessage"];
    if (fields.some(function (field) { return previous[field] !== entry[field]; })) return false;
    if (JSON.stringify(previous.contentActions || []) !== JSON.stringify(entry.contentActions || []) ||
        JSON.stringify(previous.childRuns || []) !== JSON.stringify(entry.childRuns || [])) return false;
    var before = previous.processEntries || [], after = entry.processEntries || [];
    return before.length === after.length && after.every(function (child, index) { return sameEntry(before[index], child); });
  }

  function update(item, entry, context, openContent) {
    var changed = item.__dshContext !== context || !sameEntry(item.__dshEntry, entry);
    item.__dshEntry = entry;
    item.__dshContext = context;
    item.__dshOpenContent = openContent;
    item.dataset.messageKey = String(entry.id);
    item.className = "conversation-entry dsh-upstream-entry " +
      (entry.kind === "message" ? (entry.role === "用户" ? "entry-user" : "entry-agent") : "entry-" + entry.kind);
    if (changed) paint(item);
  }

  function dispose(item) {
    pending.delete(item);
    var components = global.CodexBridgeDesktopDSHConversationComponents;
    if (components && item.__dshHost) components.dispose(item.__dshHost);
  }

  function reveal(item) {
    var components = global.CodexBridgeDesktopDSHConversationComponents;
    if (pending.has(item)) item.__dshRevealPending = true;
    else if (components && item.__dshHost) components.reveal(item.__dshHost);
  }

  global.addEventListener("dsh-conversation-components-ready", function () {
    scriptReady = true; paintPending();
  });
  global.CodexBridgeDesktopDSHConversationView = { create: create, update: update, dispose: dispose, reveal: reveal };
}(window));
