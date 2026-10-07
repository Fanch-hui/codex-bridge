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
  function createTunnelHTTPProxyForm(emit) {
    var context = { emit: emit, canSetHTTPProxy: false, httpProxy: "" };
    var form = S.node("div", "form-grid");
    var proxy = S.textField("Tunnel HTTP(S) 代理（可选）", "", "http://127.0.0.1:7897");
    proxy.control.autocomplete = "off";
    form.appendChild(proxy.wrapper);
    form.appendChild(S.node("div", "form-guide-note full",
      "留空直接连接。填写 HTTP(S) 代理地址，不含账号、密码、路径、查询参数或片段，仅用于 Tunnel 控制面；系统代理和环境变量不会自动采用。保存后会重新连接已启用的 Tunnel。"));
    var draft = D.bind({ httpProxy: proxy.control });
    var actions = S.node("div", "form-actions full");
    var save = S.button("保存代理", null, {}, null, "small", true);
    actions.appendChild(save);
    form.appendChild(actions);
    function validate() {
      save.disabled = !context.canSetHTTPProxy || proxy.control.value.trim() === context.httpProxy;
    }
    proxy.control.addEventListener("input", validate);
    proxy.control.addEventListener("compositionend", validate);
    save.addEventListener("click", function () {
      if (!save.disabled) {
        context.emit("setTunnelHTTPProxy", { httpProxy: draft.values().httpProxy.trim() || null });
      }
    });
    return { root: form, update: function (tunnel, nextEmit) {
      context.emit = nextEmit;
      context.canSetHTTPProxy = tunnel.canSetHTTPProxy === true;
      context.httpProxy = tunnel.httpProxy || "";
      draft.update({ httpProxy: context.httpProxy });
      proxy.control.disabled = !context.canSetHTTPProxy;
      validate();
    } };
  }
  function createAgentRegistration(emit) {
    var context = { emit: emit, providers: [], enabled: false };
    var wrapper = S.node("div", "page-message");
    wrapper.appendChild(S.node("h4", null, "登记 Agent"));
    var provider = S.selectField("Provider", "", [], function () {}, "");
    var qoderDistribution = S.selectField("Qoder 地区", "cn", [], function () {}, "");
    var name = S.textField("显示名称", "", "Agent 名称");
    var executable = S.textField("可执行路径", "", "由系统弹窗选取，或手动输入绝对路径");
    var configuration = S.textField("配置路径", "", "需要配置时填写（如 cordis.yml）");
    var draft = D.bind({
      providerID: provider.control,
      qoderDistribution: qoderDistribution.control,
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
      if (id === "qoder") {
        return "Qoder SDK 引擎。选择 CLI 所属地区；认证、模型偏好和原生会话严格按地区隔离。CN 使用 qodercn / qoderclicn，国际版使用 qoder / qodercli。";
      }
      if (id === "pi") {
        return "Pi RPC 引擎。选择已安装的 pi 命令，Windows 可选择 pi.cmd。需要 Node.js 22.19+；模型认证沿用本机 Pi 配置。只读任务关闭写入及 Shell，完整任务的工具操作按本机配置执行。";
      }
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
    grid.appendChild(qoderDistribution.wrapper);
    grid.appendChild(name.wrapper);
    grid.appendChild(executable.wrapper);
    grid.appendChild(configuration.wrapper);
    wrapper.appendChild(grid);
    wrapper.appendChild(guide);
    function updateProviderPresentation() {
      var selected = getProvider(provider.control.value);
      guide.textContent = guideText(selected);
      qoderDistribution.wrapper.hidden = !selected || selected.providerID !== "qoder";
      var requiresConfiguration = !!(selected && selected.requiresConfiguration);
      configuration.control.disabled = !requiresConfiguration;
      configuration.control.placeholder = requiresConfiguration
        ? "需要配置时填写（如 cordis.yml）" : "当前 Provider 无需配置文件";
    }
    provider.control.addEventListener("change", function () {
      var selected = getProvider(provider.control.value);
      if (selected) {
        draft.reset({
          providerID: selected.providerID,
          qoderDistribution: selected.providerID === "qoder"
            ? selected.qoderDistribution || "cn" : "",
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
      context.emit("beginAgentRegistration", {
        providerID: provider.control.value || null,
        qoderDistribution: provider.control.value === "qoder"
          ? qoderDistribution.control.value : null
      });
    });
    actions.appendChild(quickSelect);
    var register = S.button("按上方路径登记", null, {}, null, "small", true);
    register.addEventListener("click", function () {
      var values = draft.values();
      if (!values.executable) {
        context.emit("beginAgentRegistration", {
          providerID: values.providerID || null,
          qoderDistribution: values.providerID === "qoder" ? values.qoderDistribution : null
        });
        return;
      }
      var selected = getProvider(values.providerID);
      context.emit("registerAgent", {
        providerID: values.providerID,
        displayName: values.displayName,
        executable: values.executable,
        configurationPath: selected && selected.requiresConfiguration
          ? values.configurationPath || null : null,
        qoderDistribution: values.providerID === "qoder" ? values.qoderDistribution : null
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
        D.selectOptions(qoderDistribution.control, [
          { id: "cn", title: "中国版 CN" },
          { id: "international", title: "国际版" }
        ], false);
        var selected = getProvider(provider.control.value);
        if (!selected) {
          provider.control.value = "";
          draft.reset({
            providerID: "", qoderDistribution: "cn", displayName: "", executable: "",
            configurationPath: ""
          });
        } else {
          var providerChanged = provider.control.value !== selected.providerID;
          if (providerChanged) {
            provider.control.value = selected.providerID;
            draft.reset({
              providerID: selected.providerID,
              qoderDistribution: selected.providerID === "qoder"
                ? selected.qoderDistribution || "cn" : "",
              displayName: selected.displayName,
              executable: "",
              configurationPath: ""
            });
          } else {
            draft.update({
              providerID: selected.providerID,
              qoderDistribution: selected.providerID === "qoder"
                ? selected.qoderDistribution || "cn" : "",
              displayName: selected.displayName,
              executable: "",
              configurationPath: ""
            });
          }
        }
        quickSelect.disabled = !context.enabled || !context.providers.length;
        register.disabled = !context.enabled || !context.providers.length;
        updateProviderPresentation();
      }
    };
  }
  global.CodexBridgeDesktopConnectionsEditors = {
    createTunnelForm: createTunnelForm,
    createTunnelHTTPProxyForm: createTunnelHTTPProxyForm,
    createClients: global.CodexBridgeDesktopConnectionsClients.create,
    createAgentRegistration: createAgentRegistration
  };
}(window));
