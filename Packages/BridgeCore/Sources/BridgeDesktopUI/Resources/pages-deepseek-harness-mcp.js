(function (global) {
  "use strict";

  var S = global.CodexBridgeDesktopPageSupport;
  var E = global.CodexBridgeDesktopDeepSeekHarnessMCPEditor;

  function create(emit) {
    var card = S.node("div", "connection-card dsh-mcp-card");
    var heading = S.node("div", "section-heading-row");
    var title = S.node("div");
    title.appendChild(S.node("h3", null, "DeepSeek Harness MCP"));
    var summary = S.node("p", "card-subtitle dsh-mcp-summary");
    title.appendChild(summary);
    heading.appendChild(title);
    var add = S.button("添加 MCP", null, {}, null, "small primary", true);
    heading.appendChild(add);
    card.appendChild(heading);
    var list = S.node("div", "dsh-mcp-list");
    card.appendChild(list);
    var editor = E.create(emit);
    editor.root.hidden = true;
    card.appendChild(editor.root);
    var rows = new Map();
    var context = { emit: emit, canManage: false };

    add.addEventListener("click", function () {
      if (context.canManage) editor.begin(null, context.emit);
    });

    function createRow() {
      var root = S.node("div", "client-row dsh-mcp-row");
      var main = S.node("div", "row-main");
      var heading = S.node("div", "client-heading");
      var title = S.node("h3");
      var badge = S.badge("未知", "neutral");
      heading.appendChild(title);
      heading.appendChild(badge);
      main.appendChild(heading);
      var detail = S.node("p", "card-subtitle");
      main.appendChild(detail);
      root.appendChild(main);
      var controls = S.node("div", "client-controls");
      var toggle = S.button("启用", null, {}, null, "small", true);
      var edit = S.button("编辑", null, {}, null, "small", true);
      var remove = S.button("删除", null, {}, null, "small danger", true);
      controls.appendChild(toggle);
      controls.appendChild(edit);
      controls.appendChild(remove);
      root.appendChild(controls);
      var confirmation = S.node("div", "dsh-mcp-confirmation");
      confirmation.hidden = true;
      confirmation.appendChild(S.node("span", null, "删除这个 MCP 服务？"));
      var confirm = S.button("确认删除", null, {}, null, "small danger", false);
      var cancel = S.button("取消", null, {}, null, "small", false);
      confirmation.appendChild(confirm);
      confirmation.appendChild(cancel);
      root.appendChild(confirmation);
      var row = { root: root, title: title, badge: badge, detail: detail,
        toggle: toggle, edit: edit, remove: remove, confirmation: confirmation };
      toggle.addEventListener("click", function () {
        context.emit("setDeepSeekHarnessMCPServerEnabled", {
          mcpServerID: root.dataset.serverID, enabled: !row.enabled
        });
      });
      edit.addEventListener("click", function () {
        if (row.server) editor.begin(row.server, context.emit);
      });
      remove.addEventListener("click", function () { confirmation.hidden = false; });
      cancel.addEventListener("click", function () { confirmation.hidden = true; });
      confirm.addEventListener("click", function () {
        context.emit("deleteDeepSeekHarnessMCPServer", { mcpServerID: root.dataset.serverID });
        confirmation.hidden = true;
      });
      return row;
    }

    function updateRow(row, server) {
      row.server = server;
      row.enabled = !!server.enabled;
      row.root.dataset.serverID = server.id;
      row.title.textContent = server.name;
      row.badge.textContent = row.enabled ? "已启用" : "已停用";
      row.badge.className = "status-badge " + (row.enabled ? "success" : "neutral");
      var detail = server.transport === "http" ? (server.url || "HTTP") : (server.command || "stdio");
      var configured = S.safeArray(server.environment).concat(S.safeArray(server.headers))
        .filter(function (item) { return typeof item === "string" || item.hasValue !== false; }).length;
      row.detail.textContent = server.transport + " · " + detail
        + (configured ? " · " + (server.transport === "http" ? "请求头 " : "环境变量 ")
          + configured + " 项" : "");
      row.toggle.textContent = row.enabled ? "停用" : "启用";
      row.toggle.disabled = !context.canManage || server.canToggle === false;
      row.edit.disabled = !context.canManage || server.canEdit === false;
      row.remove.disabled = !context.canManage || server.canDelete === false;
      if (!context.canManage) row.confirmation.hidden = true;
    }

    function place(row, index) {
      var current = list.children[index];
      if (current !== row.root) list.insertBefore(row.root, current || null);
    }

    function update(page, nextEmit) {
      context.emit = nextEmit;
      context.canManage = page.canManageDeepSeekHarnessMCP === true;
      add.disabled = !context.canManage;
      editor.setCanManage(context.canManage);
      var visible = new Set();
      var position = 0;
      S.safeArray(page.deepSeekHarnessMCPServers).forEach(function (server) {
        var row = rows.get(server.id);
        if (!row) {
          row = createRow();
          rows.set(server.id, row);
        }
        updateRow(row, server);
        place(row, position++);
        visible.add(server.id);
      });
      rows.forEach(function (row, id) {
        if (!visible.has(id)) {
          row.root.remove();
          rows.delete(id);
        }
      });
      summary.textContent = visible.size
        ? "已配置 " + visible.size + " 个 MCP 服务。" : "尚未添加 MCP 服务。";
      list.hidden = visible.size === 0;
    }

    return { root: card, update: update };
  }

  global.CodexBridgeDesktopDeepSeekHarnessMCP = { create: create };
}(window));
