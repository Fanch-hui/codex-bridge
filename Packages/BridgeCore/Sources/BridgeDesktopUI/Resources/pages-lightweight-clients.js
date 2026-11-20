(function (global) {
  "use strict";
  var S = global.CodexBridgeDesktopPageSupport;

  function checkbox(label, checked) {
    var row = S.node("label", "lightweight-check"), control = document.createElement("input");
    control.type = "checkbox"; control.checked = !!checked;
    row.appendChild(control); row.appendChild(S.node("span", null, label));
    return { root: row, control: control };
  }
  function button(label, action, extraClass) {
    var control = S.button(label, null, {}, null, "small" + (extraClass ? " " + extraClass : ""));
    control.addEventListener("click", function () { if (!control.disabled) action(control); });
    return control;
  }
  function create(options) {
    var root = options.root, currentStatus = null, desktopState = null, editing = null, busy = false;
    var platforms = [
      { id: "codex", title: "Codex CLI" },
      { id: "codex_desktop", title: "Codex 桌面版" },
      { id: "claude", title: "Claude Code (CLI)" },
      { id: "claude_desktop", title: "Claude 桌面版" },
      { id: "opencode1", title: "OpenCode 1" },
      { id: "opencode2", title: "OpenCode 2" },
      { id: "pi", title: "Pi" },
      { id: "other", title: "其他应用" }
    ];
    var previousDefaultName = "";
    var selectNewModels = false, savedGrant = "", savedConfiguration = "", completedWrites = [], uncertainWrite = null;
    root.classList.add("lightweight-clients");
    var clientSignature = "", receiptSignature = "";
    var notice = S.node("p", "page-message"); notice.setAttribute("role", "status"); notice.hidden = true; root.appendChild(notice);
    var section = S.section(root, "已接入应用"), list = S.node("div", "lightweight-clients-list");
    section.classList.add("lightweight-client-card");
    var sectionHeader = S.node("div", "section-heading-row lightweight-clients-heading");
    var newButton = button("连接应用", function () { openEditor(null); }, "primary");
    sectionHeader.appendChild(section.firstChild); sectionHeader.appendChild(newButton);
    section.appendChild(sectionHeader);
    section.appendChild(S.node("p", "hint lightweight-card-intro", "将你的供应商模型接入本机其他 Agent 使用。"));
    section.appendChild(list);
    var editor = S.node("section", "page-section lightweight-client-card"), editorTitle = S.node("h3");
    var editorBody = S.node("div", "lightweight-clients-editor");
    editor.appendChild(editorTitle); editor.appendChild(editorBody); root.appendChild(editor); editor.hidden = true;
    var platform = S.selectField("目标应用", "", [{ id: "", title: "请选择应用" }].concat(platforms), changePlatform);
    var name = S.textField("应用名称", "", "例如：我的应用"), enabled = checkbox("启用应用", true);
    var modelHeading = S.node("h4", null, "允许使用的模型"), modelList = S.node("div", "lightweight-check-list");
    var refreshModels = button("刷新模型目录", function () {
      S.runButtonAction(refreshModels, "刷新中…", function () {
        return options.refreshModels().then(function () {
          updateModelChoices();
          inform("模型目录已刷新。");
        }).catch(function (error) { inform(error.message || "模型目录刷新失败。", "error"); return false; });
      }, "已刷新");
    });
    var connectSuppliers = button("连接供应商", function () { options.openSuppliers(); });
    connectSuppliers.classList.add("lightweight-clients-connect");
    var mcp = checkbox("允许使用 Bridge MCP", false), projectHeading = S.node("h4", null, "允许访问的项目");
    var projectList = S.node("div", "lightweight-check-list"), commands = checkbox("允许使用命令工具（仍需遵循审批策略）", false);
    var registerProject = button("添加项目", function () { options.registerProject(); });
    var identityFields = S.node("div", "lightweight-clients-fields");
    identityFields.appendChild(platform.wrapper); identityFields.appendChild(name.wrapper);
    var modelGroup = S.node("div", "lightweight-clients-group");
    var modelHeader = S.node("div", "lightweight-clients-group-heading");
    modelHeader.appendChild(modelHeading); modelHeader.appendChild(refreshModels);
    modelGroup.appendChild(modelHeader); modelGroup.appendChild(modelList); modelGroup.appendChild(connectSuppliers);
    var siwcLimit = S.node("p", "hint", "ChatGPT 登录模型由供应商控制输出长度和采样。网关会过滤客户端传入的输出 Token 上限、temperature 和 top_p。");
    siwcLimit.hidden = true; modelGroup.appendChild(siwcLimit);
    var coexistenceGroup = S.node("div", "lightweight-clients-group");
    var preserveOfficial = checkbox("保留官方登录态共存", false);
    var preserveOfficialHint = S.node("p", "hint");
    coexistenceGroup.appendChild(preserveOfficial.root);
    coexistenceGroup.appendChild(preserveOfficialHint);
    coexistenceGroup.hidden = true;
    preserveOfficial.control.addEventListener("change", function () { syncPlatformHints(platform.control.value); });
    var mcpGroup = S.node("div", "lightweight-clients-group");
    mcpGroup.appendChild(S.node("h4", null, "MCP 授权")); mcpGroup.appendChild(mcp.root);
    var mcpFields = S.node("div", "lightweight-clients-mcp-fields");
    var projectHeader = S.node("div", "lightweight-clients-group-heading");
    projectHeader.appendChild(projectHeading); projectHeader.appendChild(registerProject);
    mcpFields.appendChild(projectHeader); mcpFields.appendChild(projectList); mcpFields.appendChild(commands.root);
    mcpGroup.appendChild(mcpFields);
    var advanced = S.node("details", "lightweight-clients-compatibility");
    advanced.appendChild(S.node("summary", null, "高级设置"));
    var changeCompatibility = checkbox("调整模型兼容设置", false);
    var compatibilityFields = S.node("div", "lightweight-clients-compatibility-body");
    var disableSearch = checkbox("停用网页搜索", false), disableAgents = checkbox("停用多 Agent 功能", false);
    var disableThinking = checkbox("停用扩展思考", false);
    [disableSearch.root, disableAgents.root, disableThinking.root].forEach(function (node) {
      compatibilityFields.appendChild(node);
    });
    var compatibilityGroup = S.node("div", "lightweight-clients-group");
    compatibilityGroup.appendChild(changeCompatibility.root); compatibilityGroup.appendChild(compatibilityFields);
    changeCompatibility.control.addEventListener("change", function () {
      compatibilityFields.hidden = !changeCompatibility.control.checked;
    });
    advanced.appendChild(compatibilityGroup);
    advanced.appendChild(enabled.root); advanced.appendChild(mcpGroup);
    [identityFields, modelGroup, coexistenceGroup, advanced].forEach(function (node) { editorBody.appendChild(node); });
    var writeHint = S.node("p", "hint", "确认后写入目标应用的全局配置，模型网关会按需启动。保留当前默认模型，未设置时使用首个选中模型。");
    editorBody.appendChild(writeHint);
    var editorActions = S.node("div", "form-actions"), save = button("确认写入配置", saveClient, "primary"), close = button("取消", closeEditor);
    var checkResult = button("核对连接状态", checkConnection); checkResult.hidden = true;
    editorActions.appendChild(save); editorActions.appendChild(checkResult); editorActions.appendChild(close); editorBody.appendChild(editorActions);
    mcp.control.addEventListener("change", showMCPFields);
    modelList.addEventListener("change", function () { selectNewModels = false; showModelLimit(); });

    var receipts = S.section(root, "已应用的配置"), receiptList = S.node("div", "lightweight-clients-list");
    receipts.classList.add("lightweight-client-card"); receipts.appendChild(receiptList);
    var legacyClients = global.CodexBridgeDesktopConnectionsPage.createChatClients(options.emit);
    legacyClients.root.classList.add("lightweight-client-card"); root.appendChild(legacyClients.root);

    function inform(message, tone) {
      var area = editing ? editor : section;
      if (notice.parentNode !== area) area.insertBefore(notice, area.children[1] || null);
      notice.className = "page-message" + (tone ? " " + tone : "");
      notice.textContent = message || ""; notice.hidden = !message;
    }
    function operation(action, payload, done, triggerButton, pendingLabel) {
      if (busy) return;
      busy = true; save.disabled = true; inform("");
      var restore = triggerButton ? (triggerButton.__restoreTitle || triggerButton.textContent) : "";
      if (triggerButton) S.setButtonPending(triggerButton, true, pendingLabel || "处理中…", restore);
      options.run(action, payload, { localError: true }).then(function (value) { if (done) done(value); }).catch(function (error) {
        inform(error.message || "操作失败。", "error");
      }).finally(function () {
        busy = false; save.disabled = false;
        if (triggerButton) { S.setButtonPending(triggerButton, false, null, restore); triggerButton.disabled = false; }
      });
    }
    function checkedValues(container) {
      return Array.from(container.querySelectorAll("input")).filter(function (input) { return input.type === "checkbox" && input.checked; }).map(function (input) { return input.value; });
    }
    function appendChoices(container, choices, selected, empty) {
      S.clear(container);
      if (!choices.length) container.appendChild(S.node("p", "hint", empty));
      choices.forEach(function (item) {
        var row = checkbox(item.title, selected.indexOf(item.id) !== -1); row.control.value = item.id;
        container.appendChild(row.root);
      });
    }
    function availableModels(selected) {
      var models = S.safeArray(currentStatus && currentStatus.models).map(function (item) {
        return { id: item.id, title: item.name || item.id };
      }).filter(function (item) { return !!item.id; });
      selected.forEach(function (id) {
        if (!models.some(function (item) { return item.id === id; })) models.push({ id: id, title: id + "（目录暂不可用）" });
      });
      return models;
    }
    function showModelLimit() {
      siwcLimit.hidden = !checkedValues(modelList).some(function (id) { return id.startsWith("builtin/chatgpt-siwc/"); });
    }
    function updateModelChoices() {
      var selected = checkedValues(modelList), choices = availableModels(selected);
      if (selectNewModels) selected = choices.map(function (item) { return item.id; });
      var signature = JSON.stringify(choices);
      if (modelList.dataset.choices !== signature) {
        appendChoices(modelList, choices, selected, "还没有可授权的模型，请先配置供应商。");
        modelList.dataset.choices = signature;
      }
      showModelLimit();
      connectSuppliers.hidden = S.safeArray(currentStatus && currentStatus.models).some(function (item) { return !!item.id; });
    }
    function projects() {
      return S.safeArray(desktopState && desktopState.projects && desktopState.projects.rows).map(function (item) {
        return { id: item.projectID, title: item.name || item.projectID };
      });
    }
    function saveTitleFor(value) {
      if (value === "other") return "保存授权";
      if (value === "claude_desktop") return mcp.control.checked ? "保存并写入 MCP 配置" : "保存授权";
      return "确认写入配置";
    }
    function syncSaveButtonLabel() {
      S.syncButtonLabel(save, saveTitleFor(platform.control.value));
    }
    function showMCPFields() {
      mcpFields.hidden = !mcp.control.checked;
      syncSaveButtonLabel();
    }
    function platformTitle(id) {
      var item = platforms.find(function (entry) { return entry.id === id; });
      return item ? item.title : id;
    }
    function defaultName(value) {
      var item = platforms.find(function (entry) { return entry.id === value; });
      return item && value !== "other" ? item.title : "";
    }
    function syncPlatformHints(value) {
      var supportsCoexistence = value === "codex" || value === "claude";
      coexistenceGroup.hidden = !supportsCoexistence;
      if (!supportsCoexistence) preserveOfficial.control.checked = false;
      var coexist = supportsCoexistence && preserveOfficial.control.checked;
      if (value === "codex") {
        preserveOfficial.root.lastChild.textContent = "保留官方登录态共存（仅新增 codex_bridge 配置组，不改默认供应商）";
        preserveOfficialHint.textContent = coexist
          ? "已开启共存：直接运行 codex 继续使用官方登录模型；运行 codex -p codex_bridge 使用 Bridge 模型，可同时开两个终端并行。"
          : "默认不开启：将设为 Codex 默认供应商；勾选后保留你的官方登录为默认，用 codex -p codex_bridge 启用 Bridge 模型。";
      } else if (value === "claude") {
        preserveOfficial.root.lastChild.textContent = "保留官方登录态共存（不覆盖官方账号，同窗口可同时切官方与 Bridge 模型）";
        preserveOfficialHint.textContent = coexist
          ? "已开启共存：保留官方 claude.ai 登录态，在 Claude Code 的 /model 中选官方 Claude 自动透传官方，选 Bridge 模型走本机网关。"
          : "默认不开启：会写入网关 Token 并接管全局模型；勾选后保留官方账号，可在同一窗口随时在官方与 Bridge 模型间切换。";
      }
      writeHint.hidden = !value;
      if (value === "codex" && coexist) {
        writeHint.textContent = "确认后仅在 ~/.codex/config.toml 中添加 codex_bridge 供应商与配置组，不改动你的默认官方登录。";
      } else if (value === "codex_desktop") {
        writeHint.textContent = "Codex 桌面版只读取全局 ~/.codex/config.toml，不支持在界面内切换 profile；写入后请重启 Codex 桌面版生效，想用回官方登录时点「撤销配置」即可还原。";
      } else if (value === "claude" && coexist) {
        writeHint.textContent = "确认后写入本机网关地址与 Bridge 认证头，保留官方 claude.ai 登录态，并将所选 Bridge 模型加入 /model 列表。";
      } else if (value === "claude_desktop") {
        writeHint.textContent = "Claude 桌面版加密保存第三方网关配置，不支持外部直接写入模型：保存授权后请点「复制 3P 网关配置」，在 Claude 桌面版打开 Help → Troubleshooting → Enable Developer Mode，再进入 Developer → Configure Third-Party Inference… 导入或填写（3P 模式无法同窗口保留 claude.ai 登录）；若勾选 MCP，保存时会自动写入 claude_desktop_config.json。";
      } else if (value === "pi") {
        writeHint.textContent = "确认后将模型添加到 Pi 的 /model 列表。";
      } else if (value === "other") {
        writeHint.textContent = "保存授权后可复制地址、模型 ID 和凭据。Qoder 桌面版可在自定义模型中填写；Antigravity 的 OpenAI 企业网关使用去掉 /v1 的根地址。";
      } else {
        writeHint.textContent = "确认后写入目标应用的全局配置，模型网关会按需启动。保留当前默认模型，未设置时使用首个选中模型。";
      }
    }
    function changePlatform(value) {
      showModelLimit();
      var nextDefaultName = defaultName(value);
      if ((!editing.id && value !== "other") || !name.control.value.trim() || name.control.value === previousDefaultName) {
        name.control.value = nextDefaultName;
      }
      previousDefaultName = nextDefaultName;
      name.wrapper.hidden = value !== "other";
      syncPlatformHints(value);
      S.syncButtonLabel(save, saveTitleFor(value));
      compatibilityGroup.hidden = value !== "codex" && value !== "codex_desktop" && value !== "claude";
      disableSearch.root.hidden = disableAgents.root.hidden = value !== "codex" && value !== "codex_desktop";
      disableThinking.root.hidden = value !== "claude";
    }
    function openEditor(value) {
      if (busy || uncertainWrite) return;
      editing = value || { id: null, name: "", enabled: true, models: [], mcpEnabled: false, projectIDs: [], allowCommands: false };
      selectNewModels = !editing.id; savedGrant = ""; savedConfiguration = ""; completedWrites = []; uncertainWrite = null;
      checkResult.hidden = true; save.disabled = false; advanced.open = false;
      changeCompatibility.control.checked = false; compatibilityFields.hidden = true;
      var applied = S.safeArray(currentStatus && currentStatus.connections).find(function (entry) {
        return entry.clientID === editing.id && entry.purpose === "model" && entry.scope === "global" && entry.state === "applied";
      });
      var prior = applied && applied.compatibility || {};
      disableSearch.control.checked = !!prior.disableWebSearch;
      disableAgents.control.checked = !!prior.disableMultiAgent;
      disableThinking.control.checked = !!prior.disableThinking;
      preserveOfficial.control.checked = !!(editing.preserveOfficialLogin || prior.preserveOfficialLogin);
      editorTitle.textContent = editing.id ? "修改连接" : "连接应用";
      platform.control.options[0].disabled = !!editing.platform || !editing.id;
      platform.control.value = editing.platform || ""; previousDefaultName = defaultName(platform.control.value);
      platform.control.disabled = !!(editing.id && editing.platform);
      name.control.value = editing.name || ""; enabled.control.checked = true; enabled.root.hidden = !editing.id;
      changePlatform(platform.control.value);
      mcp.control.checked = !!editing.mcpEnabled; commands.control.checked = !!editing.allowCommands;
      appendChoices(modelList, availableModels(S.safeArray(editing.models)), S.safeArray(editing.models), "还没有可授权的模型，请先配置供应商。");
      modelList.dataset.choices = "";
      updateModelChoices();
      var selectedProjects = S.safeArray(editing.projectIDs), choices = projects();
      selectedProjects.forEach(function (id) {
        if (!choices.some(function (item) { return item.id === id; })) choices.push({ id: id, title: id + "（项目不可用）" });
      });
      appendChoices(projectList, choices, selectedProjects, "没有已注册项目。"); showMCPFields(); editor.hidden = false;
      inform("");
      var firstModel = modelList.querySelector('input[type="checkbox"]');
      if (platform.control.disabled && firstModel) firstModel.focus(); else platform.control.focus();
    }
    function closeEditor() { editing = null; editor.hidden = true; name.control.value = ""; uncertainWrite = null; }
    function grantPayload() {
      var payload = { name: name.control.value.trim(), models: checkedValues(modelList), mcpEnabled: mcp.control.checked,
        projectIDs: checkedValues(projectList), allowCommands: commands.control.checked };
      if (platform.control.value) payload.platform = platform.control.value;
      if (platform.control.value === "codex" || platform.control.value === "claude") {
        payload.preserveOfficialLogin = preserveOfficial.control.checked;
      }
      if (editing.id) { payload.id = editing.id; payload.enabled = enabled.control.checked; }
      return payload;
    }
    function grantSignature(payload) {
      return JSON.stringify({ name: payload.name, models: payload.models, mcpEnabled: payload.mcpEnabled,
        projectIDs: payload.projectIDs, allowCommands: payload.allowCommands, platform: payload.platform,
        preserveOfficialLogin: !!payload.preserveOfficialLogin, enabled: payload.enabled !== false });
    }
    function storedGrant(item) {
      return grantSignature({ name: item.name, models: S.safeArray(item.models), mcpEnabled: !!item.mcpEnabled,
        projectIDs: S.safeArray(item.projectIDs), allowCommands: !!item.allowCommands,
        platform: item.platform, preserveOfficialLogin: !!item.preserveOfficialLogin, enabled: item.enabled });
    }
    function defaultModel(item) {
      var current = S.safeArray(currentStatus && currentStatus.connections).find(function (entry) {
        return entry.clientID === item.id && entry.purpose === "model" && entry.scope === "global"
          && entry.state === "applied" && S.safeArray(item.models).indexOf(entry.model) !== -1;
      });
      return current ? current.model : item.models[0];
    }
    function successMessage(saved) {
      var other = saved && saved.platform === "other";
      var disabled = saved && !saved.enabled;
      var platformID = saved && saved.platform;
      var coexist = !!(saved && saved.preserveOfficialLogin);
      var hasModels = !!(saved && S.safeArray(saved.models).length);
      var hasMCP = !!(saved && saved.mcpEnabled);
      var message = "连接成功，配置已写入。请在目标应用中开始新会话，必要时重启应用。";
      if (platformID === "codex" && coexist) {
        message = "连接成功，已保留官方登录态。直接运行 codex 继续使用官方模型，运行 codex -p codex_bridge 使用 Bridge 模型。";
      } else if (platformID === "codex_desktop") {
        message = "连接成功，已写入全局配置。请重启 Codex 桌面版生效；想用回官方登录时点「撤销配置」即可还原。";
      } else if (platformID === "claude" && coexist) {
        message = "连接成功，已保留官方登录态。在 Claude Code 中使用 /model 可随时在官方 Claude 与 Bridge 模型间切换，必要时重启会话生效。";
      } else if (platformID === "claude_desktop") {
        if (hasModels && hasMCP) {
          message = "已写入 Claude 桌面版 MCP 配置并保存模型授权。请点击「复制 3P 网关配置」，在 Claude 桌面版 Developer → Configure Third-Party Inference… 中导入或填写，重启生效。";
        } else if (hasModels) {
          message = "已保存 Claude 桌面版模型授权。请点击「复制 3P 网关配置」，在 Claude 桌面版 Developer → Configure Third-Party Inference… 中导入或填写，重启生效。";
        } else if (hasMCP) {
          message = "已写入 Claude 桌面版 MCP 配置（claude_desktop_config.json），请重启 Claude 桌面版生效。";
        }
      }
      if (other) message = "应用授权已保存，可复制接入配置。";
      if (disabled) message = "应用授权已停用。";
      return message;
    }
    function checkConnection() {
      if (busy || !uncertainWrite) return;
      var pending = uncertainWrite;
      busy = true; editorBody.inert = true; close.disabled = true;
      S.setButtonPending(checkResult, true, "核对中…", "核对连接状态");
      inform("正在核对连接状态…");
      options.refreshStatus().then(function (snapshot) {
        if (!snapshot) throw new Error("暂时无法读取连接状态。");
        if (pending.stage === "gateway" && snapshot.gateway && snapshot.gateway.running) {
          uncertainWrite = null;
        } else if (pending.stage === "grant") {
          var matches = S.safeArray(snapshot.clients).filter(function (item) {
            return (editing.id ? item.id === editing.id : pending.clients.indexOf(item.id) === -1)
              && storedGrant(item) === pending.grant;
          });
          if (matches.length === 1) { editing = matches[0]; savedGrant = pending.grant; uncertainWrite = null; }
        } else if (pending.stage === "apply") {
          var applied = S.safeArray(snapshot.connections).some(function (entry) {
            return pending.receipts.indexOf(entry.receiptID) === -1 && entry.clientID === editing.id
              && entry.agent === editing.platform && entry.purpose === pending.purpose
              && entry.scope === "global" && entry.state === "applied";
          });
          if (applied) { completedWrites.push(pending.purpose); uncertainWrite = null; }
        }
        if (!uncertainWrite) {
          checkResult.hidden = true;
          var needsModelWrite = editing && editing.platform !== "claude_desktop" && S.safeArray(editing.models).length > 0;
          var finished = editing && editing.id && editing.platform !== "other"
            && (!needsModelWrite || completedWrites.indexOf("model") !== -1)
            && (!editing.mcpEnabled || completedWrites.indexOf("mcp") !== -1);
          if (finished && pending.stage === "apply") {
            var completed = editing;
            closeEditor(); inform(successMessage(completed));
          } else {
            inform("已核对当前状态，请继续确认写入配置。");
          }
        } else {
          inform("操作结果仍未确认，请稍后再次核对。", "warning");
        }
      }).catch(function (error) { inform(error.message || "暂时无法读取连接状态。", "error"); })
        .finally(function () {
          busy = false; editorBody.inert = false; save.disabled = !!uncertainWrite;
          S.setButtonPending(checkResult, false, null, "核对连接状态");
          checkResult.disabled = close.disabled = false;
        });
    }
    function saveClient() {
      if (busy || uncertainWrite) return;
      if (!platform.control.value) { inform("请选择目标应用。", "warning"); platform.control.focus(); return; }
      var value = name.control.value.trim();
      if (!value) { inform("请填写应用名称。", "warning"); name.control.focus(); return; }
      var payload = grantPayload();
      if (payload.enabled !== false && !payload.models.length && !payload.mcpEnabled) {
        inform("请选择允许使用的模型，或启用 MCP 授权。", "warning"); modelHeading.scrollIntoView({ block: "nearest" }); return;
      }
      var requestedGrant = grantSignature(payload);
      var requestedConfiguration = JSON.stringify([requestedGrant, changeCompatibility.control.checked,
        preserveOfficial.control.checked, disableSearch.control.checked, disableAgents.control.checked,
        disableThinking.control.checked]);
      if (savedConfiguration && savedConfiguration !== requestedConfiguration) completedWrites = [];
      savedConfiguration = requestedConfiguration;
      var originalClients = S.safeArray(currentStatus && currentStatus.clients).map(function (item) { return item.id; });
      var originalReceipts = S.safeArray(currentStatus && currentStatus.connections).map(function (item) { return item.receiptID; });
      var stage = "gateway", purpose = "";
      var saveIdleLabel = saveTitleFor(platform.control.value);
      var savePendingLabel = (platform.control.value === "other"
        || (platform.control.value === "claude_desktop" && !mcp.control.checked)) ? "保存中…" : "写入中…";
      busy = true; editorBody.inert = true; close.disabled = true;
      S.setButtonPending(save, true, savePendingLabel, saveIdleLabel);
      inform("正在准备连接…");
      var task = Promise.resolve();
      if (payload.models.length && !(currentStatus && currentStatus.gateway && currentStatus.gateway.running)) {
        task = task.then(function () { return options.run("service.setEnabled", { enabled: true }, { localError: true }); });
      }
      task = task.then(function () {
        stage = "grant";
        if (editing.id && (savedGrant || storedGrant(editing)) === requestedGrant) return editing;
        return options.run(editing.id ? "clients.update" : "clients.create", payload, { localError: true });
      }).then(function (saved) {
        if (!saved || !saved.id) {
          var error = new Error("应用授权回执无效，请核对连接状态。");
          error.code = "invalid_client_receipt"; throw error;
        }
        editing = saved; savedGrant = requestedGrant;
        if (saved.platform === "other" || !saved.enabled || (!saved.models.length && !saved.mcpEnabled)) return;
        var purposes = [];
        if (saved.models.length && saved.platform !== "claude_desktop") purposes.push("model");
        if (saved.mcpEnabled) purposes.push("mcp");
        if (!purposes.length) return;
        return purposes.reduce(function (chain, nextPurpose) {
          if (completedWrites.indexOf(nextPurpose) !== -1) return chain;
          return chain.then(function () {
            purpose = nextPurpose; stage = "preview";
            var request = { clientID: saved.id, agent: saved.platform, purpose: purpose, scope: "global" };
            if (purpose === "model") {
              request.model = defaultModel(saved);
              var isCodex = saved.platform === "codex" || saved.platform === "codex_desktop";
              var allowCoexist = (saved.platform === "codex" || saved.platform === "claude") && preserveOfficial.control.checked;
              var allowCompat = (isCodex || saved.platform === "claude") && changeCompatibility.control.checked;
              if (allowCoexist || allowCompat) {
                request.compatibility = {};
                if (allowCoexist) request.compatibility.preserveOfficialLogin = true;
                if (allowCompat) {
                  if (disableSearch.control.checked && isCodex) request.compatibility.disableWebSearch = true;
                  if (disableAgents.control.checked && isCodex) request.compatibility.disableMultiAgent = true;
                  if (disableThinking.control.checked && saved.platform === "claude") request.compatibility.disableThinking = true;
                }
              }
            }
            inform("正在写入" + (purpose === "model" ? "模型" : "MCP") + "配置…");
            return options.run("connections.preview", request, { localError: true });
          }).then(function (result) {
            if (!result || !result.id) throw new Error("配置预览无效，请重新确认。");
            stage = "apply";
            return options.run("connections.apply", { id: result.id }, { localError: true });
          }).then(function (result) {
            if (!result || !result.receiptID) {
              var error = new Error("配置写入回执无效，请核对连接状态。");
              error.code = "invalid_connection_receipt"; throw error;
            }
            completedWrites.push(purpose);
          });
        }, Promise.resolve());
      }).then(function () {
        var completed = editing;
        closeEditor();
        inform(successMessage(completed));
      }).catch(function (error) {
        if (["embedded_dsh_transport_timeout", "service_unavailable", "internal_error", "invalid_client_receipt", "invalid_connection_receipt"].indexOf(error.code) !== -1 && stage !== "preview") {
          uncertainWrite = { stage: stage, purpose: purpose, grant: requestedGrant,
            clients: originalClients, receipts: originalReceipts };
          checkResult.hidden = false;
          inform("操作结果尚未确认，请先核对连接状态。");
          return;
        }
        var prefix = savedGrant ? "授权已保存，配置尚未全部写入。" : "";
        inform(prefix + (error.message || "连接失败，请重试。"), "error");
      }).finally(function () {
        busy = false; editorBody.inert = false;
        S.setButtonPending(save, false, null, saveIdleLabel);
        save.disabled = !!uncertainWrite; close.disabled = false;
      });
    }
    function copyConnection(item, copyBtn) {
      if (busy) return;
      busy = true;
      var restoreLabel = item.platform === "claude_desktop" ? "复制 3P 网关配置" : "复制接入配置";
      S.setButtonPending(copyBtn, true, "复制中…", restoreLabel);
      options.copy(item.id).then(function () {
        S.flashButtonSuccess(copyBtn, "已复制");
        if (item.platform === "claude_desktop") {
          inform("已复制 Claude 桌面版 3P 网关 JSON 配置（含访问凭据）。可在 Developer → Configure Third-Party Inference… 中导入或填写。");
        } else {
          inform(S.safeArray(item.models).length ? "配置已复制，请妥善保管其中的访问凭据。" : "MCP 配置已复制。");
        }
      }).catch(function (error) {
        S.setButtonPending(copyBtn, false, null, restoreLabel);
        inform(error.message || "复制失败。", "error");
      }).finally(function () { busy = false; if (copyBtn) copyBtn.disabled = false; });
    }
    function renderClients() {
      S.clear(list); var clients = S.safeArray(currentStatus && currentStatus.clients);
      if (!clients.length) list.appendChild(S.node("p", "hint lightweight-empty-note", "还没有接入应用。"));
      clients.forEach(function (item) {
        var row = S.node("div", "lightweight-client-row"), description = S.node("div", "lightweight-client-description");
        var titleRow = S.node("div", "plugin-card-title-row");
        titleRow.appendChild(S.node("strong", "plugin-card-title", item.name));
        var selectedPlatform = platforms.find(function (entry) { return entry.id === item.platform; });
        var connections = S.safeArray(currentStatus && currentStatus.connections).filter(function (entry) {
          return entry.clientID === item.id && entry.state === "applied" && entry.scope === "global"
            && entry.generation === item.generation;
        });
        var hasModels = S.safeArray(item.models).length > 0;
        var hasMCPConnection = connections.some(function (entry) { return entry.purpose === "mcp"; });
        var connected = (hasModels || item.mcpEnabled)
          && (!hasModels || connections.some(function (entry) { return entry.purpose === "model"; }))
          && (!item.mcpEnabled || hasMCPConnection);
        var statusText = "已停用", statusTone = "neutral";
        if (item.enabled) { statusText = connected ? "已连接" : "等待配置"; statusTone = connected ? "success" : "warning"; }
        if (item.enabled && item.platform === "other") { statusText = "已授权"; statusTone = "running"; }
        if (item.enabled && item.platform === "claude_desktop") {
          if (item.mcpEnabled && !hasMCPConnection) { statusText = "等待配置"; statusTone = "warning"; }
          else if (hasModels) { statusText = "已授权"; statusTone = "running"; }
          else if (item.mcpEnabled) { statusText = "已连接"; statusTone = "success"; }
        }
        titleRow.appendChild(S.badge(statusText, statusTone));
        description.appendChild(titleRow);
        var coexistNote = "";
        if (item.preserveOfficialLogin) {
          coexistNote = item.platform === "codex" ? " · 与官方共存（codex -p codex_bridge）" : " · 与官方共存";
        }
        description.appendChild(S.node("span", "hint", (selectedPlatform && selectedPlatform.title !== item.name ? selectedPlatform.title + " · " : "")
          + "已授权 " + S.safeArray(item.models).length + " 个模型" + (item.mcpEnabled ? " · MCP 已启用" : "") + coexistNote));
        var actions = S.node("div", "form-actions");
        var editLabel = connected ? "修改模型" : "继续连接";
        if (item.platform === "other" || (item.platform === "claude_desktop" && !connected)) editLabel = "修改授权";
        actions.appendChild(button(editLabel, function () { openEditor(item); }));
        var gatewayRunning = !!(currentStatus && currentStatus.gateway && currentStatus.gateway.running);
        if (item.platform === "other") {
          var copy = button("复制接入配置", function (copyBtn) { copyConnection(item, copyBtn); });
          copy.disabled = !item.enabled || !item.mcpEnabled && !hasModels
            || hasModels && !gatewayRunning;
          actions.appendChild(copy);
        } else if (item.platform === "claude_desktop" && hasModels) {
          var copy3P = button("复制 3P 网关配置", function (copyBtn) { copyConnection(item, copyBtn); });
          copy3P.disabled = !item.enabled || !gatewayRunning;
          actions.appendChild(copy3P);
        }
        if ((item.platform === "other" || item.platform === "claude_desktop") && item.enabled && hasModels && !gatewayRunning) {
          actions.appendChild(button("启动模型网关", function (startBtn) {
            var startedMessage = item.platform === "claude_desktop"
              ? "模型网关已启动，可复制 3P 网关配置。"
              : "模型网关已启动，可复制接入配置。";
            operation("service.setEnabled", { enabled: true }, function () { inform(startedMessage); }, startBtn, "启动中…");
          }));
        }
        actions.appendChild(button("撤销", function (revokeBtn) {
          S.confirmDialog({
            title: "撤销应用访问",
            message: "确定撤销“" + item.name + "”的访问？该应用将无法继续使用对应凭据。",
            confirmTitle: "撤销访问",
            danger: true,
            fallbackText: "撤销“" + item.name + "”的访问？该应用将无法继续使用对应凭据。"
          }).then(function (confirmed) {
            if (confirmed) operation("clients.revoke", { id: item.id }, function () { inform("已撤销应用访问。"); }, revokeBtn, "撤销中…");
          });
        }, "danger"));
        row.appendChild(description); row.appendChild(actions); list.appendChild(row);
      });
    }
    function renderReceipts() {
      S.clear(receiptList); var items = S.safeArray(currentStatus && currentStatus.connections);
      receipts.hidden = !items.length;
      items.forEach(function (item) {
        var row = S.node("div", "lightweight-client-row"), copy = S.node("div", "lightweight-client-description");
        var titleRow = S.node("div", "plugin-card-title-row");
        titleRow.appendChild(S.node("strong", "plugin-card-title", platformTitle(item.agent)));
        titleRow.appendChild(S.badge(item.state === "pending" ? "待确认" : "已应用", item.state === "pending" ? "warning" : "success"));
        copy.appendChild(titleRow);
        var detailParts = [item.purpose === "mcp" ? "MCP" : "模型", item.scope === "project" ? "项目范围" : "全局范围"];
        if (item.compatibility && item.compatibility.preserveOfficialLogin) {
          detailParts.push(item.agent === "codex" ? "与官方共存（codex -p codex_bridge）" : "与官方共存");
        }
        if (item.model) {
          var modelEntry = availableModels([item.model]).find(function (entry) { return entry.id === item.model; });
          detailParts.push(modelEntry ? modelEntry.title : item.model);
        }
        copy.appendChild(S.node("span", "hint", detailParts.join(" · ")));
        row.appendChild(copy);
        row.appendChild(button("撤销配置", function (revertBtn) {
          S.confirmDialog({
            title: "撤销配置写入",
            message: "确定撤销这项 Bridge 配置？目标应用中的其他设置会保留。",
            confirmTitle: "撤销配置",
            danger: true,
            fallbackText: "撤销这项 Bridge 配置？其他设置会保留。"
          }).then(function (confirmed) {
            if (confirmed) operation("connections.revert", { receiptID: item.receiptID }, function () { inform("已撤销配置。"); }, revertBtn, "撤销中…");
          });
        }));
        receiptList.appendChild(row);
      });
    }
    return { update: function (status, state) {
      currentStatus = status; desktopState = state;
      var clients = JSON.stringify([status.clients || [], status.connections || [], status.gateway && status.gateway.running]);
      var receipts = JSON.stringify([status.connections || [], status.models || []]);
      if (clients !== clientSignature) { clientSignature = clients; renderClients(); }
      if (receipts !== receiptSignature) { receiptSignature = receipts; renderReceipts(); }
      legacyClients.update(state && state.connections, options.emit);
      if (editing) {
        updateModelChoices();
        var selectedProjects = checkedValues(projectList), projectOptions = projects();
        selectedProjects.forEach(function (id) {
          if (!projectOptions.some(function (item) { return item.id === id; })) projectOptions.push({ id: id, title: id });
        });
        var nextProjects = JSON.stringify(projectOptions);
        if (projectList.dataset.choices !== nextProjects) {
          appendChoices(projectList, projectOptions, selectedProjects, "没有已注册项目。");
          projectList.dataset.choices = nextProjects;
        }
      }
    } };
  }
  global.CodexBridgeDesktopLightweightClients = { create: create };
}(window));
