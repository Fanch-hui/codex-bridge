(function (global) {
  "use strict";
  var S = global.CodexBridgeDesktopPageSupport, E = global.CodexBridgeDesktopProjectEditors;
  var newKey = "$new";

  function create(projectID) {
    var root = S.node("div", "page-card"), mode = E.mode(projectID);
    root.appendChild(S.node("h3", null, "Direct 工作区")); root.appendChild(mode.root);
    var commands = collection(projectID, {
      title: "已登记命令", add: "新建命令", empty: "暂无已登记命令。", key: "commands", id: "commandID",
      capability: "canSaveCommand", factory: E.command, selectFirst: true,
      row: function (record) {
        var copy = S.node("div", "row-main");
        copy.appendChild(S.node("div", "row-title", record.name));
        copy.appendChild(S.node("div", "row-detail mono", record.executable + " " + S.safeArray(record.arguments).join(" ")));
        return copy;
      }
    });
    var blacklist = collection(projectID, {
      title: "命令黑名单", add: "新增规则", empty: "暂无黑名单规则。", key: "blacklist", id: "ruleID",
      capability: "canSaveBlacklist", factory: E.blacklist, selectFirst: false,
      row: function (record) { return S.node("span", "row-main mono", record.executable || record.pattern || record.ruleID); }
    });
    root.appendChild(commands.root); root.appendChild(blacklist.root);
    function setAvailable(available) {
      mode.setAvailable(available); commands.setAvailable(available); blacklist.setAvailable(available);
    }
    return {
      root: root, setAvailable: setAvailable,
      update: function (workspace, emit) {
        if (!workspace) { setAvailable(false); return; }
        mode.update(workspace, emit); commands.update(workspace, emit); blacklist.update(workspace, emit);
      }
    };
  }

  function collection(projectID, config) {
    var root = S.node("section"), heading = S.node("div", "section-heading-row");
    heading.appendChild(S.node("h4", null, config.title));
    var add = S.button(config.add, null, {}, null, "small", true); heading.appendChild(add);
    var list = S.node("div", "list-body"), editorHost = S.node("div");
    root.appendChild(heading); root.appendChild(list); root.appendChild(editorHost);
    var editors = new Map(), selectedKey = null, knownIDs = new Set();
    var current = { workspace: null, records: [], emit: null };
    add.addEventListener("click", function () { if (!add.disabled) select(newKey); });

    function select(key) {
      selectedKey = key;
      var editor = editors.get(key);
      if (!editor) {
        editor = config.factory(projectID); editors.set(key, editor); editorHost.appendChild(editor.root);
      }
      editors.forEach(function (item, id) { item.root.hidden = id !== key; });
      var record = current.records.find(function (item) { return item[config.id] === key; });
      editor.update(current.workspace, record, current.emit);
    }

    function acknowledgeCreation(records) {
      var draft = editors.get(newKey);
      if (!draft) return;
      var created = records.find(function (record) {
        return !knownIDs.has(record[config.id]) && draft.matchesSubmission(record);
      });
      if (!created) return;
      var id = created[config.id]; editors.delete(newKey); editors.set(id, draft);
      if (selectedKey === newKey) selectedKey = id;
    }

    function update(workspace, emit) {
      var records = S.safeArray(workspace[config.key]);
      current = { workspace: workspace, records: records, emit: emit };
      acknowledgeCreation(records);
      knownIDs = new Set(records.map(function (record) { return record[config.id]; }));
      add.disabled = !workspace[config.capability];
      renderList(records);
      if (selectedKey === null) selectedKey = config.selectFirst && records.length ? records[0][config.id] : newKey;
      if (selectedKey !== newKey && !knownIDs.has(selectedKey)) selectedKey = newKey;
      editors.forEach(function (editor, key) {
        if (key !== newKey && !knownIDs.has(key)) editor.setAvailable(false);
      });
      select(selectedKey);
    }

    function renderList(records) {
      S.clear(list);
      records.forEach(function (record) {
        var row = S.node("button", "list-row"); row.type = "button";
        row.appendChild(config.row(record));
        row.addEventListener("click", function () { select(record[config.id]); }); list.appendChild(row);
      });
      if (!records.length) list.appendChild(S.node("div", "list-empty", config.empty));
    }

    return {
      root: root, update: update,
      setAvailable: function (available) {
        add.disabled = !available; editors.forEach(function (editor) { editor.setAvailable(available); });
      }
    };
  }

  global.CodexBridgeDesktopProjectWorkspace = { create: create };
}(window));
