(function (global) {
  "use strict";
  var S = global.CodexBridgeDesktopPageSupport, T = global.CodexBridgeDesktopEmbeddedDSHTransport;
  function create() {
    var menu = S.node("details", "workbench-queued-menu dsh-composer-queue"), summary = S.node("summary", null, "排队 0 条");
    var list = S.node("ul", "workbench-queued-list"), items = [], sessionID = null, connected = false;
    var revision = 0, busy = new Set(), editing = null, error = "", signature = "";
    menu.hidden = true; menu.appendChild(summary); menu.appendChild(list);
    function content(item) {
      return S.safeArray(item.content).map(function (part) {
        if (part && part.type === "text") return part.text || "";
        return "[附件]";
      }).join("\n");
    }
    function canEdit(item) { return S.safeArray(item.content).every(function (part) { return part && part.type === "text"; }); }
    function perform(item, action) {
      var id = sessionID;
      if (!id || busy.has(item.id)) return;
      busy.add(item.id); error = ""; draw(true);
      T.call("session.updateQueue", { sessionId: id, itemId: item.id, action: action }).then(function () {
        if (id !== sessionID) return;
        editing = null; return refresh();
      }).catch(function (failure) {
        if (id === sessionID) error = failure && failure.message || "队列操作失败，请重试。";
      }).finally(function () { busy.delete(item.id); if (id === sessionID) draw(true); });
    }
    function button(title, callback, disabled) {
      var result = S.button(title, null, {}, null, "small");
      result.disabled = disabled; result.addEventListener("click", callback); return result;
    }
    function draw(force) {
      var next = JSON.stringify(items) + "|" + error + "|" + Array.from(busy).join(",");
      summary.textContent = "排队 " + items.length + " 条";
      menu.hidden = !items.length && !error;
      if (!force && (next === signature || editing && items.some(function (item) { return item.id === editing.id; }))) return;
      signature = next; S.clear(list);
      if (error) {
        var issue = S.node("li", "hint", error); issue.setAttribute("role", "status");
        issue.appendChild(button("重试", function () { error = ""; refresh(); }, false)); list.appendChild(issue);
      }
      items.forEach(function (item) {
        var row = S.node("li", "dsh-queued-item"), label = S.node("span", "dsh-queued-text", content(item));
        var controls = S.node("div", "dsh-queued-controls"), pending = busy.has(item.id);
        if (editing && editing.id === item.id) {
          var input = S.node("textarea", "dsh-queued-edit"); input.value = editing.text; input.setAttribute("aria-label", "编辑排队消息");
          input.addEventListener("input", function () { editing.text = input.value; }); row.appendChild(input);
          controls.appendChild(button("保存", function () {
            if (!editing.text.trim()) { error = "请输入消息内容。"; draw(true); return; }
            perform(item, { kind: "edit", content: [{ type: "text", text: editing.text }] });
          }, pending));
          controls.appendChild(button("取消", function () { editing = null; error = ""; draw(true); }, pending));
        } else {
          row.appendChild(label);
          if (item.target === "next-turn") controls.appendChild(button("立即插入", function () { perform(item, { kind: "steer" }); }, pending));
          if (canEdit(item)) controls.appendChild(button("编辑", function () {
            editing = { id: item.id, text: content(item) }; error = ""; draw(true);
            var field = list.querySelector(".dsh-queued-edit"); if (field) field.focus();
          }, pending));
          controls.appendChild(button(pending ? "处理中…" : "移除", function () { perform(item, { kind: "remove" }); }, pending));
        }
        row.appendChild(controls); list.appendChild(row);
      });
    }
    function refresh() {
      if (!sessionID || !connected) return Promise.resolve();
      var id = sessionID, ticket = revision;
      return T.read("session.queue:" + id, function () { return T.call("session.queue", { sessionId: id }); }).then(function (value) {
        if (ticket !== revision || id !== sessionID) return;
        items = S.safeArray(value && value.items);
        if (editing && !items.some(function (item) { return item.id === editing.id; })) editing = null;
        error = ""; draw(false);
      }).catch(function (failure) {
        if (ticket !== revision || id !== sessionID) return;
        error = failure && failure.message || "队列读取失败，请重试。"; draw(true);
      });
    }
    return { root: menu, refresh: refresh, setSession: function (id, ready) {
      if (sessionID === id && connected === ready) return;
      sessionID = id; connected = ready; revision++; items = []; editing = null; error = ""; signature = ""; menu.open = false;
      draw(true); if (id && ready) refresh();
    } };
  }
  global.CodexBridgeDesktopEmbeddedDSHQueue = { create: create };
}(window));
