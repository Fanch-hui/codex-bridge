(function (global) {
  "use strict";
  var S = global.CodexBridgeDesktopPageSupport, D = global.CodexBridgeDesktopFormDraft;
  var T = global.CodexBridgeDesktopEmbeddedDSHTransport;
  function mergeModelIDs(current, discovered) {
    var ids = String(current || "").split(/\r?\n/).concat(S.safeArray(discovered).map(function (model) {
      return model && model.id;
    }));
    return Array.from(new Set(ids.filter(function (id) { return typeof id === "string"; }).map(function (id) {
      return id.trim();
    }).filter(Boolean)));
  }
  function modelWithContext(id, existing, count, updateContext) {
    var model = { ...(existing || { id: id }) };
    if (updateContext || !existing) {
      if (count) model.contextWindow = count; else delete model.contextWindow;
    }
    return model;
  }
  function create(onModelsChanged, onRestart, onConnectionReady) {
    var root = S.node("div", "dsh-engine-settings-content"), active = false, state = {}, generation = 0;
    var navigation = S.node("nav", "dsh-settings-navigation"), body = S.node("div", "dsh-settings-body");
    navigation.setAttribute("aria-label", "工作台设置分类"); root.appendChild(navigation); root.appendChild(body);
    var category = "models", categories = [];
    var sessionID = null, authTimer = null, mcpEditingID = null, mcpEnabled = true, wasAuthenticated = false;
    var setupMode = null, setupRevision = 0, apiProviderID = null, chatgptReady = false;
    var activations = {}, pluginInstaller = null, deferredApplyError = "";
    var retryKeyRequired = false, retryKeyURL = "", editingHasKey = false, editorRevision = 0;
    var contextWindowDirty = false, modelIDsDirty = false, observedModelIDs = [], omittedModelIDs = new Set();
    var noticeRevision = 0;
    var actionFeedback = global.CodexBridgeDesktopEmbeddedDSHActionFeedback.create(root, {
      error: error, success: showNotice, revision: function () { return noticeRevision; },
      label: function (control, value) { return control === saveButton ? (setupMode ? "连接" : "保存连接") : value; }
    });
    var modelSection = S.section(body, "模型连接"), accountRows = S.node("div", "settings-stack");
    var activationLabels = {};
    function activationLabel(section, key) {
      var label = S.node("p", "hint"); label.hidden = true; label.setAttribute("role", "status");
      section.appendChild(label); activationLabels[key] = label;
    }
    activationLabel(modelSection, "models");
    var chatStatus = S.node("p", "hint"), accountActions = S.node("div", "form-actions");
    modelSection.appendChild(chatStatus); modelSection.appendChild(accountRows); modelSection.appendChild(accountActions);
    var login = button("使用 ChatGPT 登录", beginLogin, "auth");
    var addAccount = button("添加账号", beginAddAccount, "auth");
    var cancelLogin = button("取消登录", function () {
      return runAction(cancelLogin, "auth", "取消中…", "已取消登录。", function () { return perform("auth.cancel", {}); });
    }, "auth");
    var logout = button("退出当前账号", function () {
      return runAction(logout, "auth", "退出中…", "已退出当前账号。", function () { return perform("auth.signOut", {}); });
    }, "auth");
    var refreshModelsButton = button("刷新模型", function () {
      return runAction(refreshModelsButton, "auth", "刷新中…", "模型已刷新。", function () { return perform("auth.refreshModels", {}, function (chat) {
        if (chat && chat.authenticated && chat.planEnabled && chat.availability === "ready"
          && !chat.error && S.safeArray(chat.models).length) return connectionReady("chatgpt", true);
        error(new Error("读取 ChatGPT 模型失败，请重试。")); return false;
      }); });
    }, "auth");
    [login, addAccount, cancelLogin, logout, refreshModelsButton].forEach(function (item) { accountActions.appendChild(item); });

    var savedConnections = S.node("div", "settings-stack"); modelSection.appendChild(savedConnections);
    var editor = S.node("details", "agent-details"); editor.appendChild(S.node("summary", null, "自定义 API"));
    var form = S.node("div", "settings-stack"); editor.appendChild(form); modelSection.appendChild(editor);
    var name = S.textField("连接名称", "", "例如：我的模型服务");
    var baseURL = S.textField("API 地址", "", "https://example.com/v1");
    var apiKey = S.textField("API Key", "", "留空保留已保存的密钥"); apiKey.control.type = "password";
    var protocol = S.selectField("协议", "chat-completions", [
      { id: "chat-completions", title: "Chat Completions" }, { id: "responses", title: "Responses" }
    ], function () {});
    var modelIDs = S.textAreaField("模型 ID", "", "获取模型后可编辑，也可每行填写一个");
    var modelHeader = S.node("div", "dsh-api-model-header"), discoverButton = button("获取模型", function () {
      return runAction(discoverButton, "api-editor", "获取中…", null, discoverModels);
    }, "api-editor");
    modelHeader.appendChild(modelIDs.wrapper.firstChild); modelHeader.appendChild(discoverButton);
    modelIDs.wrapper.insertBefore(modelHeader, modelIDs.control);
    var contextWindow = S.textField("上下文长度", "", "使用模型默认值"); contextWindow.control.inputMode = "numeric";
    contextWindow.control.addEventListener("input", function () { contextWindowDirty = true; });
    [baseURL, apiKey, modelIDs].forEach(function (field) { form.appendChild(field.wrapper); });
    var modelDiscoveryStatus = S.node("p", "hint"); modelDiscoveryStatus.hidden = true;
    modelDiscoveryStatus.setAttribute("role", "status"); form.appendChild(modelDiscoveryStatus);
    var reasoningEditor = S.node("details", "agent-details"), reasoningRows = S.node("div", "settings-stack");
    reasoningEditor.appendChild(S.node("summary", null, "模型推理强度"));
    reasoningEditor.appendChild(reasoningRows); form.appendChild(reasoningEditor);
    var configuredModels = new Map(), reasoningOptions = [
      { id: "off", title: "服务默认" }, { id: "minimal", title: "极低" }, { id: "low", title: "低" },
      { id: "medium", title: "中" }, { id: "high", title: "高" }, { id: "xhigh", title: "极高" }, { id: "max", title: "最大" }
    ];
    modelIDs.control.addEventListener("input", function () {
      var current = modelIDValues();
      observedModelIDs.forEach(function (id) { if (current.indexOf(id) === -1) omittedModelIDs.add(id); });
      current.forEach(function (id) { omittedModelIDs.delete(id); });
      observedModelIDs = current; modelIDsDirty = true; renderReasoningRows();
    });
    renderReasoningRows();
    var useWithoutKey = button("不使用 API Key", function () { retryKeyRequired = false; useWithoutKey.hidden = true; showNotice(""); });
    useWithoutKey.hidden = true; form.insertBefore(useWithoutKey, modelIDs.wrapper);
    baseURL.control.addEventListener("input", function () {
      if (retryKeyRequired && baseURL.control.value.trim() !== retryKeyURL) {
        retryKeyRequired = false; useWithoutKey.hidden = true;
      }
    });
    var advanced = S.node("details", "agent-details dsh-api-advanced");
    advanced.appendChild(S.node("summary", null, "更多选项"));
    [name, protocol, contextWindow].forEach(function (field) { advanced.appendChild(field.wrapper); });
    form.appendChild(advanced);
    var editingID = null, formActions = S.node("div", "form-actions");
    var saveButton = button("保存连接", function () {
      return runAction(saveButton, "api-editor", "保存中…", "连接已保存。", saveConnection);
    }, "api-editor");
    var newConnectionButton = button("新建连接", clearEditor, "api-editor");
    [saveButton, newConnectionButton].forEach(function (item) { formActions.appendChild(item); });
    form.appendChild(formActions);

    var pluginSection = S.section(body, "插件"), pluginList = S.node("div", "settings-stack");
    activationLabel(pluginSection, "plugins");
    var pluginProgress = S.node("div", "form-actions"), pluginProgressText = S.node("span", "hint");
    pluginProgress.setAttribute("role", "status"); pluginProgress.appendChild(pluginProgressText);
    pluginSection.appendChild(pluginProgress);
    var pluginSpec = S.textField("插件包", "", "输入插件包名称");
    pluginSection.appendChild(pluginList); pluginSection.appendChild(pluginSpec.wrapper);
    var pluginActions = S.node("div", "form-actions");
    var installPluginButton = button("安装插件", function () {
      var spec = pluginSpec.control.value.trim();
      if (!spec) { error(new Error("请填写插件包名称。")); return; }
      return pluginInstaller.begin(spec);
    }, "plugin-install");
    var cancelPluginInstallButton = button("取消安装", function () { return pluginInstaller.cancel(); });
    var dismissPluginInstallButton = button("关闭进度", function () { pluginInstaller.dismiss(); });
    pluginProgress.appendChild(cancelPluginInstallButton); pluginProgress.appendChild(dismissPluginInstallButton);
    var refreshPluginsButton = button("刷新", function () {
      return runAction(refreshPluginsButton, "plugin-refresh", "刷新中…", "插件列表已刷新。", refreshPlugins);
    }, "plugin-refresh");
    pluginActions.appendChild(installPluginButton); pluginActions.appendChild(refreshPluginsButton); pluginSection.appendChild(pluginActions);
    pluginInstaller = global.CodexBridgeDesktopEmbeddedDSHPluginInstall.create({
      transport: T, root: pluginProgress, message: pluginProgressText, input: pluginSpec.control,
      installButton: installPluginButton, cancelButton: cancelPluginInstallButton, dismissButton: dismissPluginInstallButton,
      onError: error, onChanged: function () { refreshPlugins(); refreshActivation(); },
      onPending: function (pending) {
        Array.from(pluginList.querySelectorAll("button")).forEach(function (control) {
          if (!control.dataset.pluginUpdate) return;
          if (pending) {
            if (control.dataset.pluginPriorDisabled === undefined) control.dataset.pluginPriorDisabled = control.disabled ? "1" : "0";
            control.disabled = true;
          } else if (control.dataset.pluginPriorDisabled !== undefined) {
            control.disabled = control.dataset.pluginPriorDisabled === "1";
            delete control.dataset.pluginPriorDisabled;
          }
        });
      }
    });
    var mcpSection = S.section(body, "MCP 服务"), mcpList = S.node("div", "settings-stack");
    activationLabel(mcpSection, "mcp");
    mcpSection.appendChild(mcpList);
    var mcpEditor = S.node("details", "agent-details");
    mcpEditor.appendChild(S.node("summary", null, "添加 MCP 服务")); mcpSection.appendChild(mcpEditor);
    var mcpForm = S.node("div", "settings-stack"); mcpEditor.appendChild(mcpForm);
    var mcpName = S.textField("服务名称", "", "MCP 服务名称");
    var mcpTransport = S.selectField("传输方式", "stdio", [
      { id: "stdio", title: "本地程序" }, { id: "streamable-http", title: "HTTP" }
    ], function () { updateMCPFields(); });
    var mcpCommand = S.textField("程序路径", "", "本地 MCP 程序");
    var mcpArgs = S.textAreaField("程序参数", "", "每行一个参数");
    var mcpURL = S.textField("服务地址", "", "https://example.com/mcp");
    var mcpEnv = S.textAreaField("环境变量", "", "JSON 对象，留空保留已有配置");
    var mcpHeaders = S.textAreaField("请求头", "", "JSON 对象，留空保留已有配置");
    [mcpName, mcpTransport, mcpCommand, mcpArgs, mcpURL, mcpEnv, mcpHeaders].forEach(function (field) { mcpForm.appendChild(field.wrapper); });
    var mcpActions = S.node("div", "form-actions");
    var saveMCPButton = button("保存服务", function () {
      return runAction(saveMCPButton, "mcp-editor", "保存中…", "MCP 服务已保存。", saveMCP);
    }, "mcp-editor");
    mcpActions.appendChild(saveMCPButton); mcpActions.appendChild(button("新建服务", clearMCP, "mcp-editor"));
    mcpForm.appendChild(mcpActions); updateMCPFields();

    var permissionSection = S.section(body, "当前会话权限"), permissionStatus = S.node("p", "hint");
    var permission = S.selectField("权限模式", "", [], function (value) {
      if (!sessionID || !value || permission.control.disabled) return;
      var current = sessionID;
      permission.control.disabled = true; permissionStatus.textContent = "正在更新权限…";
      perform("permissions.set", { sessionId: current, presetId: value }, function (result) {
        if (sessionID !== current) return false;
        renderPermissions(result);
      }).then(function (success) {
        if (sessionID !== current) return;
        if (success) permissionStatus.textContent = "权限已更新。";
        else refreshPermissions();
      }).finally(function () { permission.control.disabled = false; });
    });
    permissionSection.appendChild(permissionStatus); permissionSection.appendChild(permission.wrapper);
    var skillSection = S.section(body, "技能"), skillList = S.node("div", "settings-stack");
    var refreshSkillsButton = button("刷新技能", function () {
      return runAction(refreshSkillsButton, "skills-refresh", "刷新中…", "技能列表已刷新。", refreshSkills);
    }, "skills-refresh");
    skillSection.appendChild(skillList); skillSection.appendChild(refreshSkillsButton);
    [["models", "模型连接", modelSection], ["skills", "技能", skillSection],
     ["mcp", "MCP 服务", mcpSection], ["plugins", "插件", pluginSection],
     ["permissions", "权限", permissionSection]].forEach(function (item) {
      var control = button(item[1], function () { selectCategory(item[0]); });
      control.classList.add("dsh-settings-category"); navigation.appendChild(control);
      categories.push({ id: item[0], section: item[2], control: control });
    });
    var notice = S.node("p", "page-message"); notice.setAttribute("role", "status"); body.appendChild(notice);
    var restartButton = button("空闲后应用变更", function () {
      return runAction(restartButton, "restart", "正在安排…", null, function () {
        return T.call("runtime.applyWhenIdle", {}).then(function (result) {
          deferredApplyError = "";
          showNotice(result && result.applied ? "变更已生效。" : "当前任务结束后自动应用变更。");
          return refreshActivation();
        });
      });
    }, "restart");
    restartButton.hidden = true; body.appendChild(restartButton);
    selectCategory("models");

    function selectCategory(value) {
      if (!categories.some(function (item) { return item.id === value; })) value = "models";
      category = value;
      categories.forEach(function (item) {
        item.section.hidden = item.id !== category;
        item.control.setAttribute("aria-current", item.id === category ? "page" : "false");
      });
    }
    function button(label, onClick, group, disabled) {
      return actionFeedback.button(label, onClick, group, disabled);
    }
    function runAction(control, group, progress, success, operation) {
      return actionFeedback.run(control, group, progress, success, operation);
    }
    function showNotice(text) { noticeRevision++; notice.textContent = text; notice.hidden = !text; }
    function error(value) { showNotice(value && value.message || "操作失败。"); }
    function showModelDiscovery(text) {
      modelDiscoveryStatus.textContent = text; modelDiscoveryStatus.hidden = !text;
    }
    function renderActivation() {
      Object.keys(activationLabels).forEach(function (key) {
        var item = activations[key], label = activationLabels[key], text = "";
        if (item) {
          if (item.status === "failed") text = item.error && (item.error.message || item.error) || "配置应用失败。";
          else if (item.restartRequired) text = "已保存，需在空闲时应用。";
          else if (item.status === "applying") text = "正在应用…";
          else if (item.status === "applied") text = "已生效";
          else if (item.status === "unknown") text = item.error && (item.error.message || item.error) || "正在核对生效状态。";
          else if (item.status === "saved") text = "已保存";
        }
        label.textContent = text; label.hidden = !text;
      });
      restartButton.hidden = !!setupMode || !Object.values(activations).some(function (item) {
        return item && item.restartRequired;
      });
    }
    function setActivation(key, value) {
      if (!value || typeof value !== "object") return;
      activations[key] = value; renderActivation();
    }
    function sharedRead(key, action, payload) {
      var operation = function () { return T.call(action, payload || {}); };
      return T.read ? T.read("settings." + key, operation) : operation();
    }
    function refreshActivation() {
      return sharedRead("activation", "configuration.status").then(function (value) {
        ["models", "mcp", "plugins"].forEach(function (key) { setActivation(key, value && value[key]); });
        pluginInstaller.adopt(value && value.pluginOperations);
      }).catch(function (failure) { if (active) error(failure); return false; });
    }
    function modelsChanged(providerID, force) {
      var revision = setupRevision;
      return onModelsChanged ? Promise.resolve(onModelsChanged(providerID, force)).catch(function (failure) {
        if (revision === setupRevision && active) error(failure);
        return null;
      }) : Promise.resolve(0);
    }
    function connectionReady(kind, force) {
      var providerID = kind === "chatgpt" ? "chatgpt-siwc" : apiProviderID;
      var revision = setupRevision;
      return modelsChanged(providerID, force).then(function (count) {
        if (revision !== setupRevision || !active || count === null) return false;
        if (count > 0) { if (onConnectionReady) onConnectionReady(kind, providerID); return true; }
        error(new Error("已连接，请刷新模型或填写模型 ID。")); return false;
      });
    }
    function beginLogin() {
      return runAction(login, "auth", "正在打开登录…", null, function () { return perform("auth.begin", {}); });
    }
    function beginAddAccount() {
      return runAction(addAccount, "auth", "正在打开登录…", null, function () { return perform("auth.addAccount", {}); });
    }
    function perform(action, payload, complete, onFailure) {
      showNotice("");
      return T.call(action, payload, { timeoutMs: /^plugins\.(install|update)$/.test(action) ? 300000 : 60000 }).then(function (result) {
        if (result && (result.application === "failed" || result.application === "cancelled")) {
          throw new Error(result.error && result.error.message || (result.application === "cancelled" ? "操作已取消。" : "插件操作失败。"));
        }
        return Promise.resolve(complete && complete(result)).then(function (completed) {
          if (/^auth\./.test(action)) { renderChat(result); refreshSettings(); }
          if (/^(settings|mcp|plugins)\./.test(action)) refreshActivation();
          return completed !== false;
        });
      }).catch(function (failure) { (onFailure || error)(failure); return false; });
    }
    function refreshSettings() {
      var request = ++generation;
      return sharedRead("models", "settings.get").then(function (result) {
        if (request !== generation) return;
        state = result || {}; setActivation("models", state.activation); renderChat(state.chatgpt || {}); renderConnections();
      }).catch(error);
    }
    function renderChat(chat) {
      chat = chat || {};
      var accounts = S.safeArray(chat.accounts), authenticated = chat.authenticated === true || chat.connected === true;
      if (authenticated !== wasAuthenticated) modelsChanged();
      wasAuthenticated = authenticated;
      if (chat.signingIn) chatStatus.textContent = "请在浏览器中完成授权。";
      else if (chat.error) chatStatus.textContent = chat.error;
      else if (authenticated && chat.planEnabled === false) chatStatus.textContent = "ChatGPT 尚未授权模型访问，请切换账号。";
      else chatStatus.textContent = authenticated ? "ChatGPT 已连接" : "连接 ChatGPT 后可选择账号中的模型。";
      if (authTimer) { global.clearTimeout(authTimer); authTimer = null; }
      if (active && chat.signingIn) authTimer = global.setTimeout(refreshSettings, 1500);
      login.hidden = authenticated || chat.signingIn; addAccount.hidden = !authenticated || chat.signingIn;
      cancelLogin.hidden = !chat.signingIn; logout.hidden = !authenticated || chat.signingIn;
      refreshModelsButton.hidden = !authenticated || chat.signingIn;
      S.clear(accountRows);
      accounts.forEach(function (account) {
        var row = S.node("div", "form-actions"), selected = account.id === chat.activeAccountId;
        row.appendChild(S.node("span", null, account.email || "ChatGPT 账号"));
        row.appendChild(S.node("span", "hint", selected ? "当前账号" : ""));
        if (!selected) {
          var switchAccount = button("切换", function () {
            return runAction(switchAccount, "auth", "切换中…", "已切换账号。", function () {
              return perform("auth.switchAccount", { accountId: account.id }, modelsChanged);
            });
          }, "auth");
          row.appendChild(switchAccount);
        }
        var removeAccount = button("移除", function () {
          return runAction(removeAccount, "auth", "移除中…", "账号已移除。", function () {
            return perform("auth.removeAccount", { accountId: account.id }, modelsChanged);
          });
        }, "auth");
        row.appendChild(removeAccount);
        accountRows.appendChild(row);
      });
    }
    function clearEditor() {
      editorRevision++; contextWindowDirty = false; modelIDsDirty = false; observedModelIDs = []; omittedModelIDs.clear();
      editingID = null; editingHasKey = false; retryKeyRequired = false; useWithoutKey.hidden = true;
      name.control.value = ""; baseURL.control.value = ""; apiKey.control.value = "";
      apiKey.control.placeholder = "按服务要求填写";
      protocol.control.value = "chat-completions"; modelIDs.control.value = ""; contextWindow.control.value = "";
      showModelDiscovery("");
      configuredModels.clear(); reasoningEditor.open = false; renderReasoningRows();
    }
    function modelIDValues() {
      return Array.from(new Set(modelIDs.control.value.split(/\r?\n/).map(function (value) { return value.trim(); }).filter(Boolean)));
    }
    function renderReasoningRows() {
      S.clear(reasoningRows);
      var ids = modelIDValues();
      if (!ids.length) { reasoningRows.appendChild(S.node("p", "hint", "填写模型 ID 后设置。")); return; }
      ids.forEach(function (id) {
        var model = configuredModels.get(id) || { id: id };
        configuredModels.set(id, model);
        var row = S.node("details", "agent-details"), summary = S.node("summary", null, id);
        row.appendChild(summary); reasoningRows.appendChild(row);
        row.addEventListener("toggle", function () {
          if (!row.open || row.dataset.ready) return;
          row.dataset.ready = "true";
          var levels = S.node("div", "settings-stack"), selected = S.selectField("默认强度", "", [], function (value) {
            model.defaultReasoningEffort = value || null;
          });
          var efforts = model.reasoningEfforts && typeof model.reasoningEfforts === "object" ? { ...model.reasoningEfforts } : {};
          function updateDefault() {
            var available = reasoningOptions.filter(function (option) { return Object.hasOwn(efforts, option.id); });
            if (!available.some(function (option) { return option.id === model.defaultReasoningEffort; })) {
              model.defaultReasoningEffort = available.some(function (option) { return option.id === "medium"; })
                ? "medium" : available.length ? available[0].id : null;
            }
            D.selectOptions(selected.control, available, false); selected.control.value = model.defaultReasoningEffort || "";
            selected.wrapper.hidden = !available.length;
          }
          reasoningOptions.forEach(function (option) {
            var levelRow = S.node("div", "form-actions"), label = S.node("label"), checkbox = S.node("input"); checkbox.type = "checkbox";
            checkbox.checked = Object.hasOwn(efforts, option.id);
            var wire = option.id === "off" ? null : S.node("input");
            if (wire) {
              wire.type = "text"; wire.setAttribute("aria-label", option.title + " API 参数值");
              wire.value = checkbox.checked ? efforts[option.id] : option.id; wire.disabled = !checkbox.checked;
              wire.addEventListener("input", function () {
                efforts[option.id] = wire.value.trim(); model.reasoningEfforts = { ...efforts };
              });
            }
            var originalOff = Object.hasOwn(efforts, "off") ? efforts.off : null;
            checkbox.addEventListener("change", function () {
              if (checkbox.checked) efforts[option.id] = wire ? wire.value.trim() : originalOff;
              else delete efforts[option.id];
              if (wire) wire.disabled = !checkbox.checked;
              model.reasoningEfforts = Object.keys(efforts).length ? { ...efforts } : false;
              updateDefault();
            });
            label.appendChild(checkbox); label.appendChild(document.createTextNode(option.title)); levelRow.appendChild(label);
            if (wire) levelRow.appendChild(wire);
            levels.appendChild(levelRow);
          });
          row.appendChild(levels); row.appendChild(selected.wrapper); updateDefault();
        });
      });
    }
    function editConnection(item) {
      editorRevision++; contextWindowDirty = false; modelIDsDirty = false; omittedModelIDs.clear();
      editingID = item.id; editingHasKey = !!item.hasApiKey; retryKeyRequired = false; useWithoutKey.hidden = true;
      name.control.value = item.name || ""; baseURL.control.value = item.baseURL || "";
      protocol.control.value = item.protocol || "chat-completions"; apiKey.control.value = "";
      apiKey.control.placeholder = "留空保留已保存的密钥";
      modelIDs.control.value = S.safeArray(item.models).map(function (model) { return model.id; }).join("\n");
      observedModelIDs = modelIDValues();
      configuredModels.clear();
      S.safeArray(item.models).forEach(function (model) { configuredModels.set(model.id, { ...model }); });
      renderReasoningRows();
      contextWindow.control.value = item.models && item.models[0] && item.models[0].contextWindow || "";
      showModelDiscovery("");
      editor.open = true; name.control.focus();
    }
    function saveConnection() {
      var values = modelIDValues();
      var size = contextWindow.control.value.trim(), count = size ? Number(size) : null;
      var url = baseURL.control.value.trim(), connectionName = name.control.value.trim();
      if (values.some(function (id) {
        var effort = configuredModels.get(id) && configuredModels.get(id).reasoningEfforts;
        return effort && typeof effort === "object" && !Object.keys(effort).some(function (level) { return level !== "off"; });
      })) { error(new Error("请为模型选择至少一个推理强度。")); return; }
      if (values.some(function (id) {
        var effort = configuredModels.get(id) && configuredModels.get(id).reasoningEfforts;
        return effort && typeof effort === "object" && Object.entries(effort).some(function (entry) {
          return entry[0] !== "off" && (typeof entry[1] !== "string" || !entry[1].trim());
        });
      })) { error(new Error("请填写启用档位的 API 参数值。")); return; }
      if (!url || size && (!Number.isInteger(count) || count <= 0)) {
        error(new Error("请填写 API 地址并检查上下文长度。")); return;
      }
      if (retryKeyRequired && !apiKey.control.value) {
        error(new Error("请重新输入 API Key，或明确选择不使用新密钥。")); return;
      }
      try { if (!connectionName) connectionName = new URL(url).hostname; }
      catch (_) { error(new Error("请填写有效的 API 地址。")); return; }
      var secret = apiKey.control.value; apiKey.control.value = "";
      var payload = { id: editingID || T.requestID(), name: connectionName, baseURL: url, protocol: protocol.control.value };
      var revision = setupRevision, editRevision = editorRevision, updateContext = contextWindowDirty;
      if (secret) payload.apiKey = secret;
      var discoveryFailed = false, noModels = false;
      var discovery = values.length || modelIDsDirty ? Promise.resolve(values) : T.call("models.discover", {
        baseURL: url, protocol: protocol.control.value, ...(editingID ? { provider: editingID } : {}),
        ...(secret ? { apiKey: secret } : {})
      }).then(function (result) {
        var found = S.safeArray(result && result.models).map(function (model) { return model.id; }).filter(Boolean);
        if (!found.length) discoveryFailed = true;
        return found;
      }).catch(function () {
        discoveryFailed = true; return [];
      });
      setAPIWorking(true); showNotice("");
      return discovery.then(function (ids) {
        if (revision !== setupRevision || editRevision !== editorRevision) throw new Error("连接已取消。");
        noModels = !ids.length;
        payload.models = ids.map(function (id) {
          return modelWithContext(id, configuredModels.get(id), count, updateContext);
        });
        return T.call("settings.save", payload);
      }).then(function (result) {
        var savedProviderID = result && result.savedConnectionID;
        if (!savedProviderID) throw new Error("连接已保存，请刷新模型后继续。");
        var submittedSecret = !!secret;
        secret = ""; delete payload.apiKey;
        var stillEditing = revision === setupRevision && editRevision === editorRevision;
        if (stillEditing && noModels) {
          apiProviderID = null;
          editingID = savedProviderID; editingHasKey = editingHasKey || submittedSecret;
          apiKey.control.placeholder = "留空保留已保存的密钥";
          editor.open = true;
          var modelMessage = discoveryFailed ? "连接已保存，模型暂不可用。请获取模型或手动填写模型 ID。"
            : "连接已保存，请添加模型后使用。";
          showModelDiscovery(modelMessage); showNotice(modelMessage);
        } else if (stillEditing) {
          apiProviderID = savedProviderID; clearEditor(); editor.open = false;
        }
        refreshSettings();
        if (noModels) return modelsChanged(savedProviderID).then(function () { return false; });
        return stillEditing ? connectionReady("api") : modelsChanged(savedProviderID);
      }).catch(function (failure) {
        if (secret && revision === setupRevision && editRevision === editorRevision) {
          requireKeyAgain(url);
          error(new Error((failure && failure.message || "连接失败。") + " 请重新输入 API Key。"));
        } else if (revision === setupRevision && editRevision === editorRevision) error(failure);
        return false;
      }).finally(function () { secret = ""; delete payload.apiKey; setAPIWorking(false); });
    }
    function setAPIWorking(value) {
      [name, baseURL, apiKey, protocol, modelIDs, contextWindow].forEach(function (field) { field.control.disabled = value; });
      reasoningEditor.inert = value;
      saveButton.disabled = discoverButton.disabled = newConnectionButton.disabled = useWithoutKey.disabled = value;
      form.setAttribute("aria-busy", String(value));
    }
    function requireKeyAgain(url) {
      retryKeyRequired = true; retryKeyURL = url;
      useWithoutKey.textContent = editingHasKey ? "继续使用已保存的密钥" : "不使用 API Key";
      useWithoutKey.hidden = false;
    }
    function discoverModels() {
      if (!baseURL.control.value.trim()) { error(new Error("请填写 API 地址。")); return; }
      var revision = setupRevision, editRevision = editorRevision;
      var payload = { baseURL: baseURL.control.value.trim(), protocol: protocol.control.value };
      if (editingID) payload.provider = editingID;
      if (apiKey.control.value) payload.apiKey = apiKey.control.value;
      setAPIWorking(true); showModelDiscovery("正在获取模型…");
      return perform("models.discover", payload, function (value) {
        if (revision !== setupRevision || editRevision !== editorRevision) return false;
        var models = S.safeArray(value && value.models);
        if (!models.length) {
          showModelDiscovery("模型目录为空，可手动填写模型 ID。"); return false;
        }
        modelIDs.control.value = mergeModelIDs(modelIDs.control.value, models.filter(function (model) {
          return model && !omittedModelIDs.has(model.id);
        })).join("\n");
        observedModelIDs = modelIDValues();
        renderReasoningRows();
        showModelDiscovery("当前共 " + modelIDValues().length + " 个模型。");
      }, function (failure) {
        if (revision !== setupRevision || editRevision !== editorRevision) return;
        showModelDiscovery(failure && failure.message || "获取模型失败，请重试或手动填写模型 ID。");
      }).finally(function () { delete payload.apiKey; setAPIWorking(false); });
    }
    function renderConnections() {
      S.clear(savedConnections);
      S.safeArray(state.connections).forEach(function (item) {
        var row = S.node("div", "form-actions"), group = "connection:" + item.id;
        row.appendChild(S.node("span", null, item.name || item.id));
        row.appendChild(button("编辑", function () { editConnection(item); }, group));
        var remove = button("移除", function () {
          return runAction(remove, group, "移除中…", "连接已移除。", function () {
            return perform("settings.remove", { id: item.id }, function () { return Promise.all([refreshSettings(), modelsChanged()]); });
          });
        }, group);
        row.appendChild(remove);
        savedConnections.appendChild(row);
      });
    }
    function refreshPlugins() {
      return sharedRead("plugins", "plugins.list").then(function (value) {
        setActivation("plugins", value && value.activation);
        S.clear(pluginList);
        var items = S.safeArray(value && value.bundles).map(function (item) { return { item: item, kind: "bundle" }; })
          .concat(S.safeArray(value && value.plugins).map(function (item) { return { item: item, kind: "plugin" }; }));
        if (!items.length) pluginList.appendChild(S.node("p", "hint", "暂无插件。"));
        items.forEach(function (entry) {
          var item = entry.item, id = item.entryId || item.id || item.name, row = S.node("div", "form-actions");
          if (!id) return;
          var group = "plugin:" + entry.kind + ":" + id;
          row.appendChild(S.node("span", null, item.displayName || item.name || item.moduleName || id));
          row.appendChild(S.node("span", "hint", item.enabled ? "已启用" : "未启用"));
          var toggle = button(item.enabled ? "停用" : "启用", function () {
            return runAction(toggle, group, item.enabled ? "停用中…" : "启用中…", item.enabled ? "插件已停用。" : "插件已启用。", function () {
              return perform("plugins.enable", { id: id, enabled: !item.enabled, kind: entry.kind }, refreshPlugins);
            });
          }, group, !!item.readOnlyReason || entry.kind === "bundle" && item.availability === "missing");
          row.appendChild(toggle);
          if (entry.kind === "bundle" && item.installed && item.removable) {
            var update = button("更新", function () {
              return pluginInstaller.begin((item.name || id) + "@latest");
            }, group);
            update.dataset.pluginUpdate = "true";
            if (pluginInstaller.isPending()) {
              update.dataset.pluginPriorDisabled = update.disabled ? "1" : "0"; update.disabled = true;
            }
            var remove = button("移除", function () {
              return runAction(remove, group, "移除中…", "插件已移除。", function () {
                return perform("plugins.remove", { name: item.name || id }, refreshPlugins);
              });
            }, group);
            row.appendChild(update); row.appendChild(remove);
          }
          pluginList.appendChild(row);
        });
      }).catch(function (failure) { error(failure); return false; });
    }
    function updateMCPFields() {
      var local = mcpTransport.control.value === "stdio";
      mcpCommand.wrapper.hidden = !local; mcpArgs.wrapper.hidden = !local; mcpEnv.wrapper.hidden = !local;
      mcpURL.wrapper.hidden = local; mcpHeaders.wrapper.hidden = local;
    }
    function clearMCP() {
      mcpEditingID = null; mcpEnabled = true; mcpName.control.value = ""; mcpTransport.control.value = "stdio";
      mcpCommand.control.value = ""; mcpArgs.control.value = ""; mcpURL.control.value = "";
      mcpEnv.control.value = ""; mcpHeaders.control.value = ""; updateMCPFields();
    }
    function editMCP(item) {
      mcpEditingID = item.id; mcpEnabled = item.enabled !== false;
      mcpName.control.value = item.name || ""; mcpTransport.control.value = item.transport || "stdio";
      mcpCommand.control.value = item.command || ""; mcpArgs.control.value = S.safeArray(item.args).join("\n");
      mcpURL.control.value = item.url || ""; mcpEnv.control.value = ""; mcpHeaders.control.value = "";
      updateMCPFields(); mcpEditor.open = true; mcpName.control.focus();
    }
    function secretObject(value) {
      if (!value.trim()) return undefined;
      var object = JSON.parse(value);
      if (!object || Array.isArray(object) || typeof object !== "object"
        || Object.keys(object).some(function (key) { return typeof object[key] !== "string"; })) throw new Error("配置必须是字符串键值组成的 JSON 对象。");
      return object;
    }
    function saveMCP() {
      var transport = mcpTransport.control.value, nameValue = mcpName.control.value.trim();
      if (!nameValue || transport === "stdio" && !mcpCommand.control.value.trim()
        || transport === "streamable-http" && !mcpURL.control.value.trim()) {
        error(new Error("请填写服务名称和程序路径或服务地址。")); return;
      }
      var payload = { id: mcpEditingID || T.requestID(), name: nameValue, transport: transport, enabled: mcpEnabled };
      try {
        if (transport === "stdio") {
          payload.command = mcpCommand.control.value.trim();
          payload.args = mcpArgs.control.value.split(/\r?\n/).filter(Boolean);
          payload.env = secretObject(mcpEnv.control.value);
        } else { payload.url = mcpURL.control.value.trim(); payload.headers = secretObject(mcpHeaders.control.value); }
      } catch (failure) { error(failure); return; }
      mcpEnv.control.value = ""; mcpHeaders.control.value = "";
      var submitted = [mcpEditingID, mcpName.control.value, mcpTransport.control.value, mcpCommand.control.value,
        mcpArgs.control.value, mcpURL.control.value];
      return perform("mcp.save", payload, function () {
        var unchanged = [mcpEditingID, mcpName.control.value, mcpTransport.control.value, mcpCommand.control.value,
          mcpArgs.control.value, mcpURL.control.value].every(function (value, index) { return value === submitted[index]; });
        if (unchanged && !mcpEnv.control.value && !mcpHeaders.control.value) { clearMCP(); mcpEditor.open = false; }
        return refreshMCP();
      });
    }
    function refreshMCP() {
      return sharedRead("mcp", "mcp.list").then(function (value) {
        setActivation("mcp", value && value.activation);
        S.clear(mcpList);
        var servers = S.safeArray(value && value.servers);
        if (!servers.length) mcpList.appendChild(S.node("p", "hint", "暂无 MCP 服务。"));
        servers.forEach(function (item) {
          var row = S.node("div", "form-actions"), group = "mcp:" + item.id;
          row.appendChild(S.node("span", null, item.name || item.id));
          row.appendChild(button("编辑", function () { editMCP(item); }, group));
          var toggle = button(item.enabled ? "停用" : "启用", function () {
            return runAction(toggle, group, item.enabled ? "停用中…" : "启用中…", item.enabled ? "MCP 服务已停用。" : "MCP 服务已启用。", function () {
              return perform("mcp.setEnabled", { id: item.id, enabled: !item.enabled }, refreshMCP);
            });
          }, group);
          var remove = button("移除", function () {
            return runAction(remove, group, "移除中…", "MCP 服务已移除。", function () { return perform("mcp.remove", { id: item.id }, refreshMCP); });
          }, group);
          row.appendChild(toggle); row.appendChild(remove);
          mcpList.appendChild(row);
        });
      }).catch(function (failure) { error(failure); return false; });
    }
    function renderPermissions(value) {
      var presets = S.safeArray(value && value.presets).map(function (item) {
        return typeof item === "string" ? { id: item, title: item } : { id: item.id, title: item.label || item.name || item.id };
      });
      D.selectOptions(permission.control, presets, false); permission.control.value = value && value.selected || "";
      permission.wrapper.hidden = !presets.length;
      permissionStatus.textContent = sessionID ? "" : "创建会话后设置权限。";
    }
    function refreshPermissions() {
      if (!sessionID) { renderPermissions(null); return; }
      var current = sessionID;
      sharedRead("permissions:" + current, "permissions.get", { sessionId: current }).then(function (value) {
        if (sessionID === current) renderPermissions(value);
      }).catch(error);
    }
    function refreshSkills() {
      if (!sessionID) { S.clear(skillList); skillList.appendChild(S.node("p", "hint", "创建会话后查看技能。")); return false; }
      var current = sessionID;
      return sharedRead("skills:" + current, "skills.list", { sessionId: current }).then(function (value) {
        if (sessionID !== current) return;
        S.clear(skillList);
        var skills = S.safeArray(value && value.skills);
        if (!skills.length) skillList.appendChild(S.node("p", "hint", "暂无技能。"));
        skills.forEach(function (skill) { skillList.appendChild(S.node("div", null, skill.name || skill.id)); });
      }).catch(function (failure) { error(failure); return false; });
    }
    function setActive(value) {
      if (active === value) return;
      active = value;
      pluginInstaller.setActive(value);
      if (active) {
        refreshSettings(); refreshActivation(); if (!setupMode) refreshAdvanced();
        if (deferredApplyError) showNotice(deferredApplyError);
      }
      else {
        setupRevision++;
        apiKey.control.value = ""; mcpEnv.control.value = ""; mcpHeaders.control.value = "";
        if (authTimer) global.clearTimeout(authTimer); authTimer = null;
      }
    }
    function refreshAdvanced() { refreshPlugins(); refreshMCP(); refreshPermissions(); refreshSkills(); }
    function setSetupMode(mode) {
      var nextMode = mode || null;
      if (setupMode === nextMode) { if (nextMode === "api") editor.open = true; return; }
      setupMode = nextMode; setupRevision++; apiProviderID = null;
      var simple = !!setupMode;
      navigation.hidden = simple;
      if (simple) selectCategory("models"); else selectCategory(category);
      renderActivation();
      chatStatus.hidden = accountRows.hidden = accountActions.hidden = setupMode === "api";
      savedConnections.hidden = simple;
      editor.hidden = setupMode === "chatgpt";
      newConnectionButton.hidden = simple;
      saveButton.textContent = simple ? "连接" : "保存连接";
      if (setupMode === "api") { clearEditor(); editor.open = true; baseURL.control.focus(); }
      if (active && !simple) refreshAdvanced();
    }
    function receive(item) {
      if (!item) return;
      pluginInstaller.receive(item);
      if (item.type === "configuration.applyFailed") {
        deferredApplyError = item.payload && item.payload.message || "应用变更失败，请重试。";
        if (active) showNotice(deferredApplyError);
      }
      if (item.type === "runtime.restarted") {
        deferredApplyError = "";
        if (active) showNotice("变更已生效。");
      }
      if (item.type === "auth.changed") {
        var auth = item.payload || {};
        chatgptReady = !auth.signingIn && auth.authenticated && auth.planEnabled
          && auth.availability === "ready" && auth.modelsReady && !auth.error;
        if (chatgptReady) connectionReady("chatgpt");
        else if (!auth.signingIn) modelsChanged();
      }
      if (item.type === "models.changed") {
        var providerID = item.payload && item.payload.providerID;
        if (setupMode === "chatgpt" && chatgptReady && (!providerID || providerID === "chatgpt-siwc")) connectionReady("chatgpt");
        else if (setupMode === "api" && apiProviderID && (!providerID || providerID === apiProviderID)) connectionReady("api");
        else modelsChanged();
      }
      if (!active) return;
      if (/auth|model|settings/.test(item.type || "")) refreshSettings();
      if (/plugin/.test(item.type || "")) refreshPlugins();
      if (/configuration|settings|plugin|mcp/.test(item.type || "")) refreshActivation();
    }
    function setSession(id) {
      if (sessionID === id) return;
      sessionID = id; if (active) { refreshPermissions(); refreshSkills(); }
    }
    return { root: root, setActive: setActive, setSession: setSession, receive: receive, refresh: refreshSettings,
      setSetupMode: setSetupMode, selectCategory: selectCategory,
      focusSetup: function () { baseURL.control.focus(); }, beginLogin: beginLogin, beginAddAccount: beginAddAccount };
  }
  global.CodexBridgeDesktopEmbeddedDSHSettings = { create: create, mergeModelIDs: mergeModelIDs, modelWithContext: modelWithContext };
}(window));
