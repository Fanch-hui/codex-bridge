(function (global) {
  "use strict";

  var S = global.CodexBridgeDesktopPageSupport;
  var E = global.CodexBridgeDesktopDeepSeekHarnessMCPEditor;
  var D = global.CodexBridgeDesktopFormDraft;
  var fallbackScopes = [
    { id: "deepseek-harness", title: "DeepSeek Harness" },
    { id: "pi", title: "Pi" },
    { id: "qoder.cn", title: "Qoder 中国版" },
    { id: "qoder.international", title: "Qoder 国际版" }
  ];

  function create(emit, options) {
    options = options || {};
    function scopes(values) {
      return values.filter(function (item) {
        return (!options.allowedScopes || options.allowedScopes.indexOf(item.id) >= 0)
          && (!options.excludedScopes || options.excludedScopes.indexOf(item.id) < 0);
      });
    }
    var initialScopes = scopes(fallbackScopes);
    var card = S.node("div", "page-card connection-card dsh-mcp-card");
    var heading = S.node("div", "section-heading-row");
    var title = S.node("div");
    title.appendChild(S.node("h3", null, "Agent MCP 服务"));
    var summary = S.node("p", "card-subtitle dsh-mcp-summary");
    title.appendChild(summary);
    heading.appendChild(title);
    var add = S.button("添加 MCP", null, {}, null, "small primary", true);
    heading.appendChild(add);
    card.appendChild(heading);
    var scope = S.selectField("作用范围", initialScopes[0] ? initialScopes[0].id : "", initialScopes, function (value) {
      if (editor.isOpen() || value === context.scope) {
        scope.control.value = context.scope;
        return;
      }
      requestScope(value);
    }, "agent-mcp-scope");
    card.appendChild(scope.wrapper);
    var load = S.button("加载 MCP 配置", null, {}, null, "small", true);
    card.appendChild(load);
    card.appendChild(S.node(
      "p",
      "card-subtitle",
      "密钥按作用范围分别保存；每项变更仅应用到对应 Agent。"
    ));
    var list = S.node("div", "dsh-mcp-list");
    card.appendChild(list);
    var editor = E.create(emit);
    editor.root.hidden = true;
    card.appendChild(editor.root);
    var rows = new Map();
    var context = { emit: emit, canManage: false, canSelectScope: false,
      canLoad: false, scope: "deepseek-harness", pendingScope: null };
    editor.setVisibilityChange(function (isOpen) {
      scope.control.disabled = !context.canSelectScope || isOpen;
      add.disabled = !context.canManage || isOpen;
      load.disabled = !context.canLoad || isOpen;
    });

    add.addEventListener("click", function () {
      if (context.canManage) editor.begin(null, context.emit, context.scope);
    });
    load.addEventListener("click", function () {
      if (!load.disabled && scope.control.value) requestScope(scope.control.value);
    });
    function requestScope(value) {
      context.pendingScope = value;
      context.canManage = false;
      context.canSelectScope = false;
      scope.control.disabled = true;
      add.disabled = true;
      editor.setCanManage(false);
      rows.forEach(function (row) { updateRow(row, row.server, row.scope); });
      context.emit("setAgentMCPScope", { mcpServerScope: value });
    }

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
        if (toggle.disabled) return;
        context.emit("setDeepSeekHarnessMCPServerEnabled", {
          mcpServerID: row.server.id,
          mcpServerScope: row.scope,
          enabled: !row.enabled
        });
      });
      edit.addEventListener("click", function () {
        if (!edit.disabled && row.server) editor.begin(row.server, context.emit, row.scope);
      });
      remove.addEventListener("click", function () { if (!remove.disabled) confirmation.hidden = false; });
      cancel.addEventListener("click", function () { confirmation.hidden = true; });
      confirm.addEventListener("click", function () {
        if (!context.canManage) return;
        context.emit("deleteDeepSeekHarnessMCPServer", {
          mcpServerID: row.server.id,
          mcpServerScope: row.scope
        });
        confirmation.hidden = true;
      });
      return row;
    }

    function updateRow(row, server, selectedScope) {
      row.server = server;
      row.scope = selectedScope;
      row.enabled = !!server.enabled;
      row.root.dataset.serverID = server.id;
      row.title.textContent = server.name;
      S.updateStatus(row.badge, row.enabled ? "已启用" : "已停用", row.enabled ? "success" : "neutral");
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
      context.scope = page.selectedAgentMCPScope || "deepseek-harness";
      var scopeOptions = S.safeArray(page.agentMCPScopeOptions);
      scopeOptions = scopes(scopeOptions.length ? scopeOptions : fallbackScopes);
      var matching = scopeOptions.some(function (item) { return item.id === context.scope; });
      if (context.pendingScope === context.scope) context.pendingScope = null;
      context.canManage = page.canManageDeepSeekHarnessMCP === true && matching && !context.pendingScope;
      context.canLoad = page.canManageDeepSeekHarnessMCP === true && scopeOptions.length > 0;
      context.canSelectScope = context.canLoad && !context.pendingScope;
      D.selectOptions(scope.control, scopeOptions, false);
      scope.control.value = matching ? context.scope : scopeOptions[0] ? scopeOptions[0].id : "";
      scope.wrapper.hidden = !!options.allowedScopes && scopeOptions.length === 1;
      scope.control.disabled = !context.canSelectScope || editor.isOpen();
      load.hidden = matching;
      load.disabled = !context.canLoad || editor.isOpen();
      add.disabled = !context.canManage || editor.isOpen();
      editor.setCanManage(context.canManage);
      var visible = new Set();
      var position = 0;
      (matching ? S.safeArray(page.deepSeekHarnessMCPServers) : []).forEach(function (server) {
        var rowKey = context.scope + "\u001f" + server.id;
        var row = rows.get(rowKey);
        if (!row) {
          row = createRow();
          rows.set(rowKey, row);
        }
        updateRow(row, server, context.scope);
        place(row, position++);
        visible.add(rowKey);
      });
      rows.forEach(function (row, id) {
        if (!visible.has(id)) {
          row.root.remove();
          rows.delete(id);
        }
      });
      var selected = scopeOptions.find(function (item) {
        return item.id === context.scope;
      });
      summary.textContent = matching ? (selected ? selected.title : context.scope) + " · "
        + (visible.size ? "已配置 " + visible.size + " 个服务。" : "尚未添加服务。") : "选择作用范围并加载配置。";
      list.hidden = visible.size === 0;
    }

    return { root: card, update: update };
  }

  global.CodexBridgeDesktopDeepSeekHarnessMCP = { create: create };
}(window));
