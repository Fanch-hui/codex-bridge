(function (global) {
  "use strict";

  var S = global.CodexBridgeDesktopPageSupport;

  function render(page, emit) {
    var container = document.getElementById("connections-content");
    S.clear(container);
    if (!page) {
      var unavailableHeader = S.node("div");
      S.pageHeader(unavailableHeader, { title: "连接", subtitle: "正在从本机 Service 读取连接状态。", symbol: "point.3.connected.trianglepath.dotted" });
      container.appendChild(unavailableHeader);
      var unavailable = S.node("div");
      S.empty(unavailable, "连接页暂不可用", "连接本机 Service 后，可以管理 MCP 客户端、Secure Tunnel 与 Agent。");
      container.appendChild(unavailable);
      return;
    }
    var header = S.node("div");
    S.pageHeader(header, page.header);
    container.appendChild(header);
    renderSummary(container, page);
    renderLocalMCP(container, page, emit);
    renderTunnel(container, page.tunnel, emit);
    renderClients(container, page.clients, emit);
    renderAgents(container, page, emit);
    if (page.statusMessage) container.appendChild(S.node("div", "page-message", page.statusMessage));
  }

  function renderSummary(container, page) {
    var summary = S.node("div", "connection-summary");
    S.safeArray(page.summaryRows).forEach(function (row) {
      var card = S.node("div", "summary-card");
      card.appendChild(S.node("div", "summary-title", row.title));
      card.appendChild(S.node("div", "summary-value", row.value));
      summary.appendChild(card);
    });
    if (!page.summaryRows || page.summaryRows.length === 0) summary.appendChild(S.node("div", "page-message", "暂无连接摘要。"));
    container.appendChild(summary);
  }

  function renderLocalMCP(container, page, emit) {
    var section = S.section(container, "本地 MCP 客户端通道");
    var card = S.node("div", "page-card connection-card");
    card.appendChild(S.node("h3", null, "本机 MCP Endpoint"));
    card.appendChild(S.node("p", "card-subtitle", "服务地址与客户端凭证由本机 Service 管理。"));
    card.appendChild(S.node("div", "page-message mono", page.localMCPURL || "Endpoint 尚未就绪"));
    var state = S.node("div", "inline-status");
    state.appendChild(S.badge(page.localMCPState, page.localMCPState === "ready" ? "success" : "neutral"));
    if (page.canCopyLocalMCPURL) state.appendChild(S.button("复制 Endpoint", "copyLocalMCPEndpoint", {}, emit, "small", false));
    if (page.canRotateLocalMCPEndpoint) {
      var rotateEndpoint = S.button("重新生成 Endpoint", null, {}, emit, "small danger", false);
      rotateEndpoint.addEventListener("click", function () {
        if (global.confirm("重新生成本地 MCP Endpoint？现有客户端地址将立即失效。")) emit("rotateLocalMCPEndpoint", {});
      });
      state.appendChild(rotateEndpoint);
    }
    card.appendChild(state);
    section.appendChild(card);
  }

  function renderTunnel(container, tunnel, emit) {
    var section = S.section(container, "远程 AI 客户端 (OpenAI Secure Tunnel)");
    var card = S.node("div", "page-card connection-card");
    var title = S.node("div", "section-heading-row");
    title.appendChild(S.node("h3", null, "Secure MCP 隧道"));
    title.appendChild(S.badge(tunnel.lifecycle || "unknown", tunnelTone(tunnel)));
    card.appendChild(title);
    card.appendChild(S.node("p", "card-subtitle", tunnel.helperAvailable ? "Helper 已就绪，可按需连接远程通道。" : "当前环境没有可用 Helper，远程隧道不能启动。"));
    var facts = S.node("div", "detail-grid");
    addFact(facts, "绑定 Tunnel ID", tunnel.tunnelID || "未配置");
    addFact(facts, "Helper", tunnel.helperAvailable ? "就绪" : "未打包");
    addFact(facts, "远程任务接收", tunnel.acceptsRemoteSubmissions ? "允许" : "关闭");
    addFact(facts, "配置状态", tunnel.configured ? "已配置" : "未配置");
    card.appendChild(facts);
    if (tunnel.canConfigure) card.appendChild(tunnelForm(tunnel, emit));
    var actions = S.node("div", "form-actions");
    if (tunnel.canConnect) actions.appendChild(S.button("连接", "connectTunnel", {}, emit, "small primary", false));
    if (tunnel.canDisconnect) actions.appendChild(S.button("断开", "disconnectTunnel", {}, emit, "small", false));
    if (tunnel.canClear) {
      var clear = S.button("清除配置", null, {}, emit, "small danger", false);
      clear.addEventListener("click", function () {
        if (global.confirm("清除 Secure Tunnel 配置？\n这会移除已保存的 Runtime Key 并重置 Tunnel 绑定。")) emit("clearTunnel", {});
      });
      actions.appendChild(clear);
    }
    card.appendChild(actions);
    section.appendChild(card);
  }

  function tunnelForm(tunnel, emit) {
    var form = S.node("div", "form-grid");
    var id = S.textField("Tunnel ID", tunnel.tunnelID || "", "输入 Tunnel ID");
    var key = S.textField("Runtime Key", "", "不会写入 UI 状态");
    key.control.type = "password";
    key.control.autocomplete = "off";
    form.appendChild(id.wrapper);
    form.appendChild(key.wrapper);
    var action = S.node("div", "form-actions full");
    var save = S.button("保存并配置", null, {}, emit, "small primary", false);
    save.addEventListener("click", function () {
      if (!id.control.value || !key.control.value) return;
      emit("configureTunnel", { tunnelID: id.control.value, runtimeKey: key.control.value });
      key.control.value = "";
    });
    action.appendChild(save);
    form.appendChild(action);
    return form;
  }

  function renderClients(container, clients, emit) {
    var section = S.section(container, "本地 MCP 客户端");
    var card = S.node("div", "page-card connection-card");
    S.safeArray(clients).forEach(function (client) {
      var row = S.node("div", "client-row");
      var main = S.node("div", "row-main");
      main.appendChild(S.node("h3", null, client.displayName));
      main.appendChild(S.node("p", "card-subtitle", "活动 Session：" + client.activeSessionCount + (client.lastConnectedAt ? " · 最近连接：" + client.lastConnectedAt : "")));
      row.appendChild(main);
      var controls = S.node("div", "client-controls");
      var toggle = S.node("label", "check-field");
      var checkbox = S.node("input");
      checkbox.type = "checkbox";
      checkbox.checked = client.enabled;
      checkbox.disabled = !client.canToggle;
      checkbox.addEventListener("change", function () { emit("setMCPClientEnabled", { clientID: client.clientID, enabled: checkbox.checked }); });
      toggle.appendChild(checkbox);
      toggle.appendChild(S.node("span", null, "启用"));
      controls.appendChild(toggle);
      var exposure = S.selectField("工具权限", client.exposureMode, S.choices(client.exposureMode, client.exposureOptions), function (value) {
        emit("setMCPClientExposure", { clientID: client.clientID, exposureMode: value });
      }, "");
      controls.appendChild(exposure.control);
      if (client.canCopyConfiguration) controls.appendChild(S.button("复制 JSON", "copyMCPClientConfiguration", { clientID: client.clientID }, emit, "small", !client.enabled));
      if (client.canRotateCredential) {
        var rotateCredential = S.button("重新生成凭证", null, {}, emit, "small danger", !client.enabled);
        rotateCredential.addEventListener("click", function () {
          if (global.confirm("重新生成这个 MCP 客户端的凭证？现有配置将立即失效。")) emit("rotateMCPClientCredential", { clientID: client.clientID });
        });
        controls.appendChild(rotateCredential);
      }
      row.appendChild(controls);
      card.appendChild(row);
    });
    if (!clients || clients.length === 0) card.appendChild(S.node("div", "list-empty", "暂无本地 MCP 客户端。"));
    section.appendChild(card);
  }

  function renderAgents(container, page, emit) {
    var section = S.section(container, "本机 Agent 引擎连接");
    var card = S.node("div", "page-card connection-card");
    card.appendChild(S.node("h3", null, "已登记安装"));
    S.safeArray(page.installations).forEach(function (installation) { card.appendChild(agentRow(installation, emit)); });
    if (!page.installations || page.installations.length === 0) card.appendChild(S.node("div", "list-empty", "尚未登记本机 Agent。"));
    card.appendChild(agentRegistration(page.providers, emit, page.canRegisterAgent));
    section.appendChild(card);
  }

  function agentRow(installation, emit) {
    var row = S.node("div", "agent-row");
    row.appendChild(S.icon("cpu.fill", "service-icon"));
    var main = S.node("div", "row-main");
    main.appendChild(S.node("div", "row-title", installation.displayName));
    main.appendChild(S.node("div", "row-detail mono", installation.providerID + " · " + installation.executablePath));
    main.appendChild(S.node("div", "row-detail", (installation.version || "未识别") + " · " + installation.availability));
    if (installation.lastProbeError) main.appendChild(S.node("div", "row-detail", installation.lastProbeError));
    row.appendChild(main);
    var actions = S.node("div", "client-controls");
    var enabled = S.node("label", "check-field");
    var checkbox = S.node("input");
    checkbox.type = "checkbox";
    checkbox.checked = installation.enabled;
    checkbox.disabled = !installation.canToggle;
    checkbox.addEventListener("change", function () { emit("setAgentEnabled", { installationID: installation.installationID, enabled: checkbox.checked }); });
    enabled.appendChild(checkbox);
    enabled.appendChild(S.node("span", null, "启用"));
    actions.appendChild(enabled);
    actions.appendChild(S.button("Probe", "reprobeAgent", { installationID: installation.installationID, acceptReplacement: false }, emit, "small", !installation.canReprobe));
    if (installation.availability === "needs_review" && installation.canReprobe) {
      var accept = S.button("接受替换并 Probe", null, {}, emit, "small primary", false);
      accept.addEventListener("click", function () {
        if (global.confirm("接受新的 Agent 可执行文件并重新 Probe？")) emit("reprobeAgent", { installationID: installation.installationID, acceptReplacement: true });
      });
      actions.appendChild(accept);
    }
    var remove = S.button("移除", null, {}, emit, "small danger", !installation.canRemove);
    remove.addEventListener("click", function () {
      if (global.confirm("移除这个 Agent 登记？本机可执行文件不会被删除。")) emit("removeAgent", { installationID: installation.installationID });
    });
    actions.appendChild(remove);
    row.appendChild(actions);
    return row;
  }

  function agentRegistration(providers, emit, enabled) {
    var wrapper = S.node("div", "page-message");
    wrapper.appendChild(S.node("h4", null, "登记 Agent"));
    var providerList = S.safeArray(providers);
    var providerChoices = providerList.map(function (item) {
      return { id: item.providerID, title: item.displayName, detail: item.detail };
    });

    function getProvider(id) {
      for (var i = 0; i < providerList.length; i++) {
        if (providerList[i].providerID === id) return providerList[i];
      }
      return providerList[0];
    }

    function guideText(p) {
      if (!p) return "请选择要登记的 Agent Provider。";
      var id = (p.providerID || "").toLowerCase();
      if (id.indexOf("opencode") >= 0) {
        return "OpenCode CLI 引擎。无需配置文件。点击“弹窗选择文件登记…”选中 opencode.exe（npm 全局安装通常位于 %APPDATA%\\npm\\opencode.cmd）。";
      }
      if (id.indexOf("antigravity") >= 0) {
        return "Antigravity CLI 引擎。无需配置文件。点击“弹窗选择文件登记…”选中 agy.exe（通常位于 PATH 或自定义安装目录）。";
      }
      if (id.indexOf("deepseek") >= 0) {
        return "DeepSeek Harness。需要可执行文件及只读 cordis.yml 配置文件。点击“弹窗选择文件登记…”将依次弹出系统窗口指导选择。";
      }
      if (p.requiresConfiguration) {
        return p.displayName + " 需要选择可执行文件与独立的配置文件（如 cordis.yml）。";
      }
      return p.displayName + " 仅需选择本机可执行文件（.exe 或脚本），无需单独配置文件。";
    }

    var selectedProvider = providerList[0];
    var guideNode = S.node("div", "form-guide-note", guideText(selectedProvider));

    var name = S.textField("显示名称", selectedProvider ? selectedProvider.displayName : "", "Agent 名称");
    var executable = S.textField("可执行路径", "", "由系统弹窗选取，或手动输入绝对路径");
    var configuration = S.textField("配置路径", "", (selectedProvider && !selectedProvider.requiresConfiguration) ? "当前 Provider 无需配置文件" : "需要配置时填写（如 cordis.yml）");
    if (selectedProvider && !selectedProvider.requiresConfiguration) {
      configuration.control.disabled = true;
    }

    var provider = S.selectField("Provider", selectedProvider ? selectedProvider.providerID : "", providerChoices, function (newID) {
      selectedProvider = getProvider(newID);
      name.control.value = selectedProvider ? selectedProvider.displayName : "";
      guideNode.textContent = guideText(selectedProvider);
      if (selectedProvider && !selectedProvider.requiresConfiguration) {
        configuration.control.value = "";
        configuration.control.disabled = true;
        configuration.control.placeholder = "当前 Provider 无需配置文件";
      } else {
        configuration.control.disabled = false;
        configuration.control.placeholder = "需要配置时填写（如 cordis.yml）";
      }
    }, "");

    var grid = S.node("div", "form-grid");
    grid.appendChild(provider.wrapper);
    grid.appendChild(name.wrapper);
    grid.appendChild(executable.wrapper);
    grid.appendChild(configuration.wrapper);
    wrapper.appendChild(grid);
    wrapper.appendChild(guideNode);

    var action = S.node("div", "form-actions");
    var quickSelect = S.button("弹窗选择文件登记…", null, {}, emit, "small primary", !enabled || providerList.length === 0);
    quickSelect.addEventListener("click", function () {
      var currentID = provider.control.value || (selectedProvider ? selectedProvider.providerID : "");
      emit("beginAgentRegistration", { providerID: currentID });
    });
    action.appendChild(quickSelect);

    var register = S.button("按上方路径登记", null, {}, emit, "small", !enabled || providerList.length === 0);
    register.addEventListener("click", function () {
      var currentID = provider.control.value || (selectedProvider ? selectedProvider.providerID : "");
      if (!executable.control.value) {
        emit("beginAgentRegistration", { providerID: currentID });
        return;
      }
      emit("registerAgent", {
        providerID: currentID,
        displayName: name.control.value,
        executable: executable.control.value,
        configurationPath: (selectedProvider && selectedProvider.requiresConfiguration) ? (configuration.control.value || null) : null
      });
    });
    action.appendChild(register);

    wrapper.appendChild(action);
    return wrapper;
  }

  function addFact(container, title, value) {
    var item = S.node("div", "detail-item");
    item.appendChild(S.node("dt", null, title));
    item.appendChild(S.node("dd", null, value));
    container.appendChild(item);
  }

  function tunnelTone(tunnel) {
    if (tunnel.actionRequired) return "warning";
    if (tunnel.lifecycle === "ready") return "success";
    if (tunnel.enabled) return "running";
    return "neutral";
  }

  global.CodexBridgeDesktopConnectionsPage = { render: render };
}(window));
