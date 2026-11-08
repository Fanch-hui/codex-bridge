(function (global) {
  "use strict";
  var S = global.CodexBridgeDesktopPageSupport;
  var M = global.CodexBridgeDesktopSettingsModels;
  var storageKey = "codex-bridge.settings.section";

  function choiceTitle(value, choices) {
    var choice = S.safeArray(choices).find(function (item) { return item.id === value; });
    return choice ? choice.title : value || "默认";
  }

  function modelTitle(value, options) {
    var option = S.safeArray(options).find(function (item) { return item.modelID === value; });
    return option ? option.displayName : value || "Agent 默认";
  }

  function agentSummary(item) {
    if (!item.installationID) return "未连接";
    var parts = [modelTitle(item.model, item.modelOptions)];
    if (item.providerID !== "antigravity" && item.canSelectEffort !== false) {
      parts.push(choiceTitle(item.effort, item.effortOptions));
    }
    return parts.join(" · ");
  }

  function linkRow(title, detail, action) {
    var root = S.node("div", "settings-link-row");
    var copy = S.node("div", "settings-link-copy");
    var name = S.node("h3", null, title), value = S.node("p", "hint", detail || "");
    var button = S.button("管理", null, {}, null, "small", false);
    value.hidden = !detail;
    copy.appendChild(name); copy.appendChild(value);
    button.setAttribute("aria-label", "管理" + title);
    button.addEventListener("click", action);
    root.appendChild(copy); root.appendChild(button);
    return { root: root, name: name, value: value, button: button };
  }

  function group(body, title) {
    var section = S.node("section", "settings-subsection settings-link-group");
    section.appendChild(S.node("h3", null, title));
    var list = S.node("div", "settings-link-list"); section.appendChild(list); body.appendChild(section);
    return list;
  }

  function categoryNavigation(sidebar, sections) {
    var entries = new Map(), selected = null;

    function add(id, title) {
      var button = S.node("button", "settings-sidebar-item", title);
      button.type = "button";
      var pane = S.node("section", "settings-pane");
      pane.id = "settings-pane-" + id;
      button.setAttribute("aria-controls", pane.id);
      var heading = S.node("h2", "settings-pane-title", title);
      heading.id = pane.id + "-title";
      pane.setAttribute("aria-labelledby", heading.id);
      var inner = S.node("div", "settings-pane-inner");
      var body = S.node("div", "settings-stack");
      inner.appendChild(heading); inner.appendChild(body); pane.appendChild(inner);
      sidebar.appendChild(button); sections.appendChild(pane);
      entries.set(id, { button: button, pane: pane });
      button.addEventListener("click", function () { select(id); });
      return body;
    }

    function select(id) {
      if (!entries.has(id)) return false;
      selected = id;
      entries.forEach(function (entry, key) {
        var active = key === id;
        entry.pane.hidden = !active;
        if (active) entry.button.setAttribute("aria-current", "page");
        else entry.button.removeAttribute("aria-current");
      });
      try { global.localStorage.setItem(storageKey, id); } catch (_) {}
      return true;
    }

    return { add: add, select: select, has: function (id) { return entries.has(id); },
      selectedID: function () { return selected; } };
  }

  function create(container, page, emit) {
    var context = { emit: emit };
    var sidebar = S.node("aside", "settings-sidebar");
    var categoryList = S.node("nav", "settings-sidebar-list");
    categoryList.setAttribute("aria-label", "设置分类");
    var sidebarFooter = S.node("div", "settings-sidebar-footer");
    var refresh = S.button("", null, {}, null, "settings-sidebar-refresh", true);
    refresh.appendChild(S.icon("arrow.clockwise"));
    refresh.title = "刷新设置"; refresh.setAttribute("aria-label", refresh.title);
    refresh.addEventListener("click", function () { context.emit("refresh", {}); });
    sidebarFooter.appendChild(refresh);
    sidebar.appendChild(categoryList); sidebar.appendChild(sidebarFooter);
    var sections = S.node("div", "settings-panes");
    var main = S.node("div", "settings-main");
    var status = S.node("div", "page-message settings-status");
    status.setAttribute("role", "status");
    var storage = S.node("div", "settings-editor-storage"); storage.hidden = true;
    main.appendChild(sections); main.appendChild(status);
    container.appendChild(sidebar); container.appendChild(main); container.appendChild(storage);
    var categories = categoryNavigation(categoryList, sections);

    function openDSH(category) {
      if (document.documentElement.dataset.surface === "preferences") {
        context.emit("selectPage", { navigation: "workbench", kind: "dsh-settings", value: category });
      } else if (global.CodexBridgeDesktopDSHWorkbench) {
        global.CodexBridgeDesktopDSHWorkbench.openSettings(category);
      }
    }

    function openConnection(id) {
      if (document.documentElement.dataset.surface === "preferences") {
        context.emit("selectPage", { navigation: "connections", kind: "connection-detail", value: id });
      } else if (global.CodexBridgeDesktopConnectionsPage) {
        global.CodexBridgeDesktopConnectionsPage.openDetail(id, context.emit);
      }
    }

    var application = categories.add("application", "通用");
    var models = categories.add("models", "账户与模型");
    var execution = categories.add("execution", "执行与审批");
    var clients = categories.add("clients", "客户端与指令");
    var extensions = categories.add("extensions", "技能与扩展");
    var diagnostics = categories.add("diagnostics", "诊断与日志");

    var modelList = group(models, "模型连接");
    modelList.appendChild(linkRow("工作台", "ChatGPT 与自定义 API", function () { openDSH("models"); }).root);
    var agentsList = group(models, "Agent 默认模型");
    var codexRow = linkRow("Codex", "", function () { openConnection("codex"); });
    agentsList.appendChild(codexRow.root);
    var agents = agentEditors({ page: page, emit: emit, storage: storage, codexRow: codexRow,
      agentsList: agentsList, openConnection: openConnection });
    var direct = global.CodexBridgeDesktopDirect.create();
    execution.appendChild(direct.root);
    var instructions = global.CodexBridgeDesktopSettingsInstructions.create(page, emit);
    clients.appendChild(instructions.root);
    var extensionList = group(extensions, "工作台");
    [
      ["技能", "skills"], ["MCP 服务", "mcp"], ["插件", "plugins"], ["原生权限", "permissions"]
    ].forEach(function (item) {
      extensionList.appendChild(linkRow(item[0], "", function () { openDSH(item[1]); }).root);
    });
    var agentTools = group(extensions, "Agent");
    agentTools.appendChild(linkRow("Agent MCP 服务", "", function () { openConnection("agent-mcp"); }).root);
    var logs = S.button("打开日志", null, {}, null, "small", false);
    logs.addEventListener("click", function () { context.emit("openLogs", {}); });
    var logsSection = S.node("section", "settings-subsection");
    logsSection.appendChild(S.node("h3", null, "运行日志"));
    logsSection.appendChild(logs); diagnostics.appendChild(logsSection);
    function update(next, nextEmit, state) {
      context.emit = nextEmit;
      if (state) {
        refresh.disabled = !!state.isRefreshing;
        refresh.classList.toggle("is-refreshing", !!state.isRefreshing);
      }
      agents.update(next, nextEmit);
      direct.update(next.direct, nextEmit);
      instructions.update(next, nextEmit);
    }

    function open(id) {
      if (typeof id !== "string") return false;
      if (id === "codex" || id.indexOf("agent:") === 0) { openConnection(id); return true; }
      var target = id;
      if (id === "permissions" || id === "instructions") target = "clients";
      if (id === "direct") target = "execution";
      return categories.select(target);
    }

    var initial = null;
    try { initial = global.localStorage.getItem(storageKey); } catch (_) {}
    categories.select(categories.has(initial) ? initial : "application");
    return { details: { open: open, selectedID: categories.selectedID },
      execution: execution, clients: clients, application: application,
      diagnostics: diagnostics, status: status, mountAgent: agents.mountAgent, update: update };
  }

  function agentEditors(options) {
    var providers = new Map(), mounts = new Map();
    var codex = M.preferences(options.page, options.emit, true);
    var qoder = global.CodexBridgeDesktopSettingsQoderPermissions.create();
    options.storage.appendChild(codex.root);

    function provider(id, title) {
      var current = providers.get(id);
      if (current) return current;
      var body = S.node("div", "settings-stack settings-provider-detail");
      var row = linkRow(title, "", function () { options.openConnection("agent:" + id); });
      current = { body: body, row: row, editors: new Map() };
      providers.set(id, current); options.storage.appendChild(body); options.agentsList.appendChild(row.root);
      if (id === "qoder") body.appendChild(qoder.root);
      return current;
    }

    function updateItem(item, emit, keys) {
      var current = provider(item.providerID, item.providerName);
      var key = item.installationID || "default";
      if (!keys.has(item.providerID)) keys.set(item.providerID, new Set());
      keys.get(item.providerID).add(key);
      var editor = current.editors.get(key);
      if (!editor) {
        editor = global.CodexBridgeDesktopSettingsAgents.editor(item, emit);
        current.editors.set(key, editor); current.body.appendChild(editor.root);
      }
      editor.root.hidden = false; editor.update(item, emit);
      current.row.name.textContent = item.providerName;
      current.row.button.setAttribute("aria-label", "管理" + item.providerName);
      var desktopNotRunning = global.CodexBridgeDesktopSettingsAgents.desktopNotRunning(item);
      var summary = item.errorMessage || agentSummary(item);
      if (item.isRefreshingModels) summary = "正在获取模型…";
      if (desktopNotRunning) summary = "DSH 桌面版未打开";
      current.row.value.textContent = summary;
      current.row.value.hidden = !current.row.value.textContent;
    }

    function update(next, emit) {
      codex.update(next, emit);
      var summary = modelTitle(next.executionModel, next.models);
      if (next.modelError) summary = "模型获取失败：" + next.modelError;
      if (next.isRefreshingModels) summary = "正在获取模型…";
      options.codexRow.value.textContent = summary;
      options.codexRow.value.hidden = !options.codexRow.value.textContent;
      var visible = new Set(), keys = new Map();
      S.safeArray(next.agentDefaults).forEach(function (item) {
        visible.add(item.providerID); updateItem(item, emit, keys);
      });
      var policy = next.nativePermissionPolicy;
      if (policy && policy.providerID === "qoder") {
        visible.add("qoder"); provider("qoder", policy.providerName || "Qoder");
      }
      qoder.update(next, emit);
      providers.forEach(function (current, id) {
        var nextKeys = keys.get(id) || new Set();
        current.editors.forEach(function (editor, key) { editor.root.hidden = !nextKeys.has(key); });
        current.row.root.hidden = !visible.has(id);
      });
      mounts.forEach(function (target, id) { mountAgent(id, target); });
    }

    function mountAgent(id, target) {
      mounts.set(id, target);
      var body = null;
      if (id === "codex") body = codex.root;
      else if (providers.has(id)) body = providers.get(id).body;
      if (body && body.parentNode !== target) target.appendChild(body);
    }

    return { update: update, mountAgent: mountAgent };
  }

  global.CodexBridgeDesktopSettingsNavigation = { create: create };
}(window));
