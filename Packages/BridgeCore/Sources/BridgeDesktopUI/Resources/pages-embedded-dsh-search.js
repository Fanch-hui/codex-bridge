(function (global) {
  "use strict";
  var S = global.CodexBridgeDesktopPageSupport, T = global.CodexBridgeDesktopEmbeddedDSHTransport;
  function create(openResult) {
    var root = S.node("section", "dsh-session-search"), field = S.textField("搜索会话", "", "搜索对话内容");
    var results = S.node("div", "dsh-session-search-results"), note = S.node("p", "hint");
    var more = S.button("加载更多", null, {}, null, "small"), cursor = null, query = "", revision = 0, timer = null, loading = false;
    root.hidden = true; field.wrapper.querySelector("label").hidden = true; field.control.type = "search";
    field.control.setAttribute("aria-label", "搜索工作台会话"); note.setAttribute("role", "status");
    root.appendChild(field.wrapper); root.appendChild(note); root.appendChild(results); root.appendChild(more); more.hidden = true;
    function clear() { revision++; cursor = null; query = ""; note.textContent = ""; more.hidden = true; S.clear(results); }
    function search(append) {
      var value = field.control.value.trim(), ticket = ++revision;
      if (!value) { clear(); return; }
      if (!append || query !== value) { query = value; cursor = null; S.clear(results); }
      var requestCursor = cursor; loading = true; more.disabled = true; note.textContent = "正在搜索…";
      T.call("session.search", { query: value, cursor: requestCursor || undefined, limit: 20 }).then(function (response) {
        if (ticket !== revision || value !== field.control.value.trim()) return;
        var items = S.safeArray(response && response.items);
        items.forEach(function (item) {
          if (!item || !(item.sessionId || item.taskID || item.nativeSessionID)) return;
          var button = S.button("", null, {}, null, "small dsh-session-search-result");
          button.appendChild(S.node("span", "dsh-session-title", item.title || "对话"));
          var source = { workbench: "工作台", bridge: "网页工作台", agent: "Agent 原生会话" }[item.source] || "工作台";
          if (item.projectStatus === "unavailable") source += " · 项目不可用";
          button.appendChild(S.node("span", "dsh-session-search-source", source));
          if (item.excerpt) button.appendChild(S.node("span", "hint", item.excerpt));
          button.addEventListener("click", function () { openResult(item); }); results.appendChild(button);
        });
        cursor = response && response.nextCursor || null;
        more.hidden = !cursor;
        var sourceStatus = response && response.sourceStatus || {};
        var unavailable = Object.keys(sourceStatus).filter(function (source) {
          return sourceStatus[source] && ["unsupported", "unavailable"].includes(sourceStatus[source].state);
        });
        note.textContent = results.childElementCount ? "" : response && response.hasMore
          ? "当前范围没有匹配结果，可继续搜索。" : "没有找到匹配的对话。";
        if (unavailable.length) note.textContent += (note.textContent ? " " : "") + "部分来源暂不可搜索。";
        if (sourceStatus.bridge && sourceStatus.bridge.scope === "prompt" && sourceStatus.bridge.state !== "excluded") {
          note.textContent += (note.textContent ? " " : "") + "网页工作台按原始要求搜索。";
        }
        note.title = unavailable.map(function (source) {
          return ({ workbench: "工作台", bridge: "网页工作台", agent: "Agent 原生会话" })[source] || source;
        }).join("、");
      }).catch(function (error) {
        if (ticket === revision) note.textContent = error && error.message || "搜索失败，请重试。";
      }).finally(function () { if (ticket === revision) { loading = false; more.disabled = false; } });
    }
    field.control.addEventListener("input", function () {
      if (timer) global.clearTimeout(timer);
      revision++; timer = global.setTimeout(function () { timer = null; search(false); }, 250);
    });
    field.control.addEventListener("keydown", function (event) {
      if (event.key === "Escape") { root.hidden = true; clear(); }
    });
    more.addEventListener("click", function () { if (!loading && cursor) search(true); });
    return { root: root, toggle: function () { root.hidden = !root.hidden; if (!root.hidden) field.control.focus(); else clear(); } };
  }
  global.CodexBridgeDesktopEmbeddedDSHSearch = { create: create };
}(window));
