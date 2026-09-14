(function (global) {
  "use strict";

  var S = global.CodexBridgeDesktopPageSupport;
  var D = global.CodexBridgeDesktopFormDraft;
  var newID = 0;

  function textArea(label, value, placeholder) {
    var wrapper = S.node("div", "field full");
    wrapper.appendChild(S.node("label", null, label));
    var control = S.node("textarea");
    control.value = value || "";
    control.placeholder = placeholder || "";
    wrapper.appendChild(control);
    return { wrapper: wrapper, control: control };
  }

  function secretEditor(title) {
    var root = S.node("div", "dsh-mcp-secrets");
    var heading = S.node("div", "dsh-mcp-secret-heading");
    heading.appendChild(S.node("span", null, title));
    var add = S.button("添加", null, {}, null, "small", false);
    heading.appendChild(add);
    root.appendChild(heading);
    var list = S.node("div", "dsh-mcp-secret-list");
    root.appendChild(list);
    var entries = [];

    function makeEntry(name, configured) {
      var row = S.node("div", "dsh-mcp-secret-row");
      var key = S.textField("名称", name, "例如：API_KEY");
      var value = S.textField("值", "", configured ? "已配置，留空保留" : "尚未配置");
      value.control.type = "password";
      value.control.autocomplete = "new-password";
      var remove = S.button("移除", null, {}, null, "small danger", false);
      remove.addEventListener("click", function () {
        row.remove();
        entries = entries.filter(function (entry) { return entry.row !== row; });
      });
      row.appendChild(key.wrapper);
      row.appendChild(value.wrapper);
      row.appendChild(remove);
      list.appendChild(row);
      entries.push({ row: row, key: key.control, value: value.control });
    }

    add.addEventListener("click", function () { makeEntry("", false); });
    return {
      root: root,
      reset: function (configuredNames) {
        S.clear(list);
        entries = [];
        S.safeArray(configuredNames).forEach(function (item) {
          makeEntry(
            typeof item === "string" ? item : item.name,
            typeof item === "string" || item.hasValue !== false
          );
        });
      },
      values: function () {
        return entries.map(function (entry) {
          var name = entry.key.value.trim();
          if (!name) return null;
          return { name: name, value: entry.value.value || null };
        }).filter(Boolean);
      },
      clearValues: function () {
        entries.forEach(function (entry) { entry.value.value = ""; });
      }
    };
  }

  function create(emit) {
    var root = S.node("div", "dsh-mcp-editor");
    root.appendChild(S.node("p", "card-subtitle", "保存后，将在新任务或继续对话时生效。"));
    var transportHint = S.node("p", "card-subtitle dsh-mcp-transport-hint");
    root.appendChild(transportHint);
    var fields = S.node("div", "form-grid");
    var name = S.textField("名称", "", "例如：filesystem");
    var transport = S.selectField("传输方式", "stdio", [
      { id: "stdio", title: "本地命令（stdio）" },
      { id: "http", title: "HTTP 地址" }
    ], updateTransport, "");
    var command = S.textField("命令", "", "例如：/usr/local/bin/npx（Windows：C:\\Tools\\npx.cmd）");
    var url = S.textField("HTTP 地址", "", "例如：https://example.com/mcp");
    var args = textArea("参数（每行一个）", "", "--flag\nvalue");
    fields.appendChild(name.wrapper);
    fields.appendChild(transport.wrapper);
    fields.appendChild(command.wrapper);
    fields.appendChild(url.wrapper);
    fields.appendChild(args.wrapper);
    root.appendChild(fields);
    var environment = secretEditor("环境变量");
    var headers = secretEditor("HTTP 请求头");
    root.appendChild(environment.root);
    root.appendChild(headers.root);
    var actions = S.node("div", "form-actions");
    var save = S.button("保存 MCP", null, {}, null, "small primary", true);
    var cancel = S.button("取消", null, {}, null, "small", false);
    actions.appendChild(save);
    actions.appendChild(cancel);
    root.appendChild(actions);
    var draft = null;
    var draftID = null;
    var editingID = null;
    var editingEnabled = true;
    var canManage = false;
    var context = { emit: emit };

    function bindDraft(id) {
      if (draftID === id) return;
      draftID = id;
      draft = D.bind({
        name: name.control,
        transport: transport.control,
        command: command.control,
        url: url.control,
        args: args.control
      });
    }

    function updateTransport() {
      var isHTTP = transport.control.value === "http";
      transportHint.textContent = isHTTP
        ? "HTTP 服务仅在任务允许联网时连接。"
        : "命令需填写绝对路径；参数每行一个。";
      command.wrapper.hidden = isHTTP;
      args.wrapper.hidden = isHTTP;
      url.wrapper.hidden = !isHTTP;
      environment.root.hidden = isHTTP;
      headers.root.hidden = !isHTTP;
      validate();
    }

    function validate() {
      if (!draft) return;
      var values = draft.values();
      var validName = values.name.trim().length > 0;
      var validTransport = values.transport === "http"
        ? values.url.trim().length > 0
        : absoluteCommand(values.command);
      save.disabled = !canManage || !validName || !validTransport;
    }

    function absoluteCommand(value) {
      return value.charAt(0) === "/" || /^[A-Za-z]:[\\/]/.test(value)
        || value.indexOf("\\\\") === 0;
    }

    [name.control, command.control, url.control, args.control].forEach(function (control) {
      control.addEventListener("input", validate);
      control.addEventListener("compositionend", validate);
    });
    transport.control.addEventListener("change", updateTransport);
    save.addEventListener("click", function () {
      if (save.disabled) return;
      var values = draft.values();
      context.emit("saveDeepSeekHarnessMCPServer", {
        mcpServerID: editingID,
        name: values.name.trim(),
        mcpTransport: values.transport,
        mcpCommand: values.transport === "stdio" ? values.command.trim() : null,
        arguments: values.transport === "stdio" ? values.args.split(/\r?\n/).filter(function (item) {
          return item.trim().length > 0;
        }) : [],
        mcpURL: values.transport === "http" ? values.url.trim() : null,
        enabled: editingEnabled,
        mcpEnvironmentSecrets: values.transport === "stdio" ? environment.values() : [],
        mcpHeaderSecrets: values.transport === "http" ? headers.values() : []
      });
      environment.clearValues();
      headers.clearValues();
    });
    cancel.addEventListener("click", function () {
      environment.clearValues();
      headers.clearValues();
      root.hidden = true;
    });

    return {
      root: root,
      setCanManage: function (value) {
        canManage = !!value;
        validate();
      },
      begin: function (server, nextEmit) {
        context.emit = nextEmit;
        editingID = server ? server.id : "new-" + Date.now().toString(36) + "-" + (++newID);
        editingEnabled = server ? server.enabled !== false : true;
        bindDraft(editingID);
        var source = server || {};
        draft.update({
          name: source.name || "",
          transport: source.transport || "stdio",
          command: source.command || "",
          url: source.url || "",
          args: S.safeArray(source.arguments).join("\n")
        });
        environment.reset(source.environment || []);
        headers.reset(source.headers || []);
        root.hidden = false;
        updateTransport();
        validate();
        name.control.focus();
      }
    };
  }

  global.CodexBridgeDesktopDeepSeekHarnessMCPEditor = { create: create };
}(window));
