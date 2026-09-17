(function (global) {
  "use strict";
  var S = global.CodexBridgeDesktopPageSupport;
  var D = global.CodexBridgeDesktopFormDraft;
  function createTunnelForm(emit) {
    var context = { canConfigure: false, emit: emit };
    var form = S.node("div", "form-grid");
    var id = S.textField("Tunnel ID", "", "输入 Tunnel ID");
    var key = S.textField("Runtime Key", "", "不会写入 UI 状态");
    key.control.type = "password";
    key.control.autocomplete = "off";
    form.appendChild(id.wrapper);
    form.appendChild(key.wrapper);
    var draft = D.bind({ tunnelID: id.control, runtimeKey: key.control });
    var action = S.node("div", "form-actions full");
    var save = S.button("保存并启动连接", null, {}, null, "small primary", true);
    action.appendChild(save);
    form.appendChild(action);
    function validate() {
      save.disabled = !context.canConfigure || !id.control.value || !key.control.value;
    }
    id.control.addEventListener("input", validate);
    key.control.addEventListener("input", validate);
    id.control.addEventListener("compositionend", validate);
    key.control.addEventListener("compositionend", validate);
    save.addEventListener("click", function () {
      if (save.disabled) return;
      var values = draft.values();
      if (!values.tunnelID || !values.runtimeKey) return;
      context.emit("configureTunnel", {
        tunnelID: values.tunnelID,
        runtimeKey: values.runtimeKey
      });
      key.control.value = "";
      draft.update({ tunnelID: id.control.value, runtimeKey: "" });
      validate();
    });
    return {
      root: form,
      clearRuntimeKey: function () {
        key.control.value = "";
        draft.update({ tunnelID: id.control.value, runtimeKey: "" });
        validate();
      },
      update: function (tunnel, nextEmit) {
        context.canConfigure = !!tunnel.canConfigure;
        context.emit = nextEmit;
        draft.update({ tunnelID: tunnel.tunnelID || "", runtimeKey: "" });
        validate();
      }
    };
  }
  function createClients(emit) {
    var context = { emit: emit };
    var card = S.node("div", "page-card connection-card");
    var rows = new Map();
    function createRow(client) {
      var row = S.node("div", "client-row");
      var main = S.node("div", "row-main");
      var heading = S.node("div", "client-heading");
      var name = S.node("h3");
      var state = S.badge("未知", "neutral");
      heading.appendChild(name);
      heading.appendChild(state);
      main.appendChild(heading);
      var detail = S.node("p", "card-subtitle");
      main.appendChild(detail);
      row.appendChild(main);
      var controls = S.node("div", "client-controls");
      var toggle = S.node("label", "check-field");
      var checkbox = S.node("input");
      var toggleText = S.node("span");
      checkbox.type = "checkbox";
      checkbox.addEventListener("change", function () {
        context.emit("setMCPClientEnabled", {
          clientID: row.dataset.clientID,
          enabled: checkbox.checked
        });
      });
      toggle.appendChild(checkbox);
      toggle.appendChild(toggleText);
      controls.appendChild(toggle);
      var copy = S.button("复制 Qwen JSON 配置", null, {}, null, "small", true);
      copy.addEventListener("click", function () {
        context.emit("copyMCPClientConfiguration", { clientID: row.dataset.clientID });
      });
      controls.appendChild(copy);
      var rotate = S.button("重新生成凭证", null, {}, null, "small danger", true);
      rotate.addEventListener("click", function () {
        if (global.confirm("重新生成这个 MCP 客户端的凭证？现有配置将立即失效。")) {
          context.emit("rotateMCPClientCredential", { clientID: row.dataset.clientID });
        }
      });
      controls.appendChild(rotate);
      row.appendChild(controls);
      var hint = S.node("p", "client-exposure-hint");
      row.appendChild(hint);
      return {
        root: row,
        name: name,
        state: state,
        detail: detail,
        toggle: toggle, checkbox: checkbox, toggleText: toggleText,
        copy: copy,
        rotate: rotate,
        hint: hint
      };
    }
    function updateRow(row, client, nextEmit) {
      row.root.dataset.clientID = client.clientID;
      row.name.textContent = client.displayName;
      row.state.textContent = client.enabled ? "已启用" : "已停用";
      row.state.className = "status-badge " + (client.enabled ? "success" : "neutral");
      row.detail.textContent = "活动 Session：" + client.activeSessionCount
        + (client.lastConnectedAt ? " · 最近连接：" + client.lastConnectedAt : "");
      row.checkbox.checked = !!client.enabled;
      row.checkbox.disabled = !client.canToggle;
      row.toggle.hidden = !client.canToggle;
      row.toggleText.textContent = client.clientID === "qwen.studio" ? "启用 Qwen Studio" : "启用";
      row.copy.hidden = !client.canCopyConfiguration;
      row.rotate.hidden = !client.canRotateCredential;
      row.copy.disabled = !client.enabled || !client.canCopyConfiguration;
      row.rotate.disabled = !client.enabled || !client.canRotateCredential;
      row.hint.textContent = "提供完整 Agent 任务与工具能力；执行遵循项目权限和本机审批。";
      context.emit = nextEmit;
    }
    function placeRow(card, row, index) {
      var current = card.children[index];
      if (current === row.root) return;
      if (current) card.insertBefore(row.root, current);
      else card.appendChild(row.root);
    }
    return {
      root: card,
      update: function (clients, nextEmit) {
        context.emit = nextEmit;
        var visible = new Set();
        var position = 0;
        S.safeArray(clients).forEach(function (client) {
          visible.add(client.clientID);
          var row = rows.get(client.clientID);
          if (!row) {
            row = createRow(client);
            rows.set(client.clientID, row);
          }
          updateRow(row, client, nextEmit);
          placeRow(card, row, position);
          position += 1;
        });
        rows.forEach(function (row, clientID) {
          if (!visible.has(clientID)) {
            row.root.remove();
            rows.delete(clientID);
          }
        });
        if (!visible.size) {
          var empty = card.querySelector(".list-empty");
          if (!empty) card.appendChild(S.node("div", "list-empty", "暂无本地 MCP 客户端。"));
        } else {
          var emptyRow = card.querySelector(".list-empty");
          if (emptyRow) emptyRow.remove();
        }
      }
    };
  }
  function createAgentRegistration(emit) {
    var context = { emit: emit, providers: [], enabled: false };
    var wrapper = S.node("div", "page-message");
    wrapper.appendChild(S.node("h4", null, "登记 Agent"));
    var provider = S.selectField("Provider", "", [], function () {}, "");
    var name = S.textField("显示名称", "", "Agent 名称");
    var executable = S.textField("可执行路径", "", "由系统弹窗选取，或手动输入绝对路径");
    var configuration = S.textField("配置路径", "", "需要配置时填写（如 cordis.yml）");
    var draft = D.bind({
      providerID: provider.control,
      displayName: name.control,
      executable: executable.control,
      configurationPath: configuration.control
    });
    function getProvider(id) {
      return context.providers.find(function (item) { return item.providerID === id; })
        || context.providers[0];
    }
    function guideText(item) {
      if (!item) return "请选择要登记的 Agent Provider。";
      var id = (item.providerID || "").toLowerCase();
      if (id.indexOf("opencode") >= 0) {
        return "OpenCode CLI 引擎。无需配置文件。点击“弹窗选择文件登记…”选中 opencode.exe（npm 全局安装通常位于 %APPDATA%\\npm\\opencode.cmd）。";
      }
      if (id.indexOf("antigravity") >= 0) {
        return "Antigravity CLI 引擎。无需配置文件。点击“弹窗选择文件登记…”选中 agy.exe（通常位于 PATH 或自定义安装目录）。";
      }
      if (id.indexOf("deepseek") >= 0) {
        return "DeepSeek Harness。需要可执行文件及只读 cordis.yml 配置文件。点击“弹窗选择文件登记…”将依次弹出系统窗口指导选择。";
      }
      if (item.requiresConfiguration) {
        return item.displayName + " 需要选择可执行文件与独立的配置文件（如 cordis.yml）。";
      }
      return item.displayName + " 仅需选择本机可执行文件（.exe 或脚本），无需单独配置文件。";
    }
    var guide = S.node("div", "form-guide-note");
    var grid = S.node("div", "form-grid");
    grid.appendChild(provider.wrapper);
    grid.appendChild(name.wrapper);
    grid.appendChild(executable.wrapper);
    grid.appendChild(configuration.wrapper);
    wrapper.appendChild(grid);
    wrapper.appendChild(guide);
    function updateProviderPresentation() {
      var selected = getProvider(provider.control.value);
      guide.textContent = guideText(selected);
      var requiresConfiguration = !!(selected && selected.requiresConfiguration);
      configuration.control.disabled = !requiresConfiguration;
      configuration.control.placeholder = requiresConfiguration
        ? "需要配置时填写（如 cordis.yml）" : "当前 Provider 无需配置文件";
    }
    provider.control.addEventListener("change", function () {
      var selected = getProvider(provider.control.value);
      if (selected) {
        draft.update({
          providerID: selected.providerID,
          displayName: selected.displayName,
          executable: "",
          configurationPath: ""
        });
      }
      updateProviderPresentation();
    });
    var actions = S.node("div", "form-actions");
    var quickSelect = S.button("弹窗选择文件登记…", null, {}, null, "small primary", true);
    quickSelect.addEventListener("click", function () {
      context.emit("beginAgentRegistration", { providerID: provider.control.value || null });
    });
    actions.appendChild(quickSelect);
    var register = S.button("按上方路径登记", null, {}, null, "small", true);
    register.addEventListener("click", function () {
      var values = draft.values();
      if (!values.executable) {
        context.emit("beginAgentRegistration", { providerID: values.providerID || null });
        return;
      }
      var selected = getProvider(values.providerID);
      context.emit("registerAgent", {
        providerID: values.providerID,
        displayName: values.displayName,
        executable: values.executable,
        configurationPath: selected && selected.requiresConfiguration
          ? values.configurationPath || null : null
      });
    });
    actions.appendChild(register);
    wrapper.appendChild(actions);
    return {
      root: wrapper,
      update: function (providers, enabled, nextEmit) {
        context.providers = S.safeArray(providers);
        context.enabled = !!enabled;
        context.emit = nextEmit;
        D.selectOptions(provider.control, context.providers.map(function (item) {
          return { id: item.providerID, title: item.displayName, detail: item.detail };
        }));
        var selected = getProvider(provider.control.value);
        if (!selected) {
          provider.control.value = "";
          draft.update({ providerID: "", displayName: "", executable: "", configurationPath: "" });
        } else {
          if (provider.control.value !== selected.providerID) provider.control.value = selected.providerID;
          draft.update({
            providerID: selected.providerID,
            displayName: selected.displayName,
            executable: "",
            configurationPath: ""
          });
        }
        quickSelect.disabled = !context.enabled || !context.providers.length;
        register.disabled = !context.enabled || !context.providers.length;
        updateProviderPresentation();
      }
    };
  }
  global.CodexBridgeDesktopConnectionsEditors = {
    createTunnelForm: createTunnelForm,
    createClients: createClients,
    createAgentRegistration: createAgentRegistration
  };
}(window));
