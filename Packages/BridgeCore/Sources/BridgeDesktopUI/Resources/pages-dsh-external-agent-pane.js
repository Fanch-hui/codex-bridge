(function (global) {
  "use strict";
  var S = global.CodexBridgeDesktopPageSupport;
  function C() { return global.CodexBridgeDesktopWorkbenchComposer; }
  function forms() { return global.CodexBridgeDesktopFormDraft; }
  function appendAll(parent, nodes) { nodes.forEach(function (n) { parent.appendChild(n); }); return parent; }

  function sessionKey(row) {
    if (!row) return "";
    var tabs = global.CodexBridgeDesktopWorkbenchTabs;
    return tabs && tabs.sessionKey ? tabs.sessionKey(row)
      : "s:" + (row.providerID || "") + "\u001f" + (row.sessionID || row.taskID || "");
  }
  function availableAgents() {
    var composer = C();
    return S.safeArray(composer && composer.agents ? composer.agents() : []).filter(function (a) {
      return a && a.key && a.enabled !== false && a.available !== false;
    });
  }
  function buildPanePage(page, detail, row) {
    var projectID = (detail && detail.projectID) || (row && row.projectID) || (page && page.selectedProjectID) || null;
    return Object.assign({}, page || {}, {
      selectedTask: detail || null, selectedTaskID: detail ? detail.taskID : null, selectedProjectID: projectID
    });
  }
  function sameInputs(prev, next) {
    return !!prev && prev.length === next.length && next.every(function (v, i) { return v === prev[i]; });
  }

  function createAgentLauncher(options) {
    options = options || {};
    var button = S.node("button", "workbench-tab-agent-menu-btn");
    button.type = "button"; button.title = "直接打开外部 Agent 会话"; button.setAttribute("aria-label", button.title);
    button.setAttribute("aria-haspopup", "menu"); button.setAttribute("aria-expanded", "false");
    button.appendChild(S.node("span", "workbench-tab-agent-menu-label", "外部 Agent"));
    button.appendChild(S.icon("chevron.down"));
    var menu = S.node("div", "workbench-agent-launcher-menu");
    menu.setAttribute("role", "menu"); menu.hidden = true; menu.dataset.browserOccluder = "";
    var header = appendAll(S.node("div", "workbench-agent-launcher-header"), [
      S.node("p", "workbench-agent-launcher-title", "直接打开外部 Agent"),
      S.node("p", "workbench-agent-launcher-subtitle", "点 + 默认新建工作台对话")
    ]);
    var list = S.node("div", "workbench-agent-launcher-list");
    var root = appendAll(S.node("span", "workbench-agent-launcher"), [button, appendAll(menu, [header, list])]);

    function renderList() {
      S.clear(list);
      var agents = availableAgents();
      if (!agents.length) {
        var empty = S.node("p", "workbench-agent-launcher-empty", "暂无可用外部 Agent，请先在连接页启用并连接");
        empty.setAttribute("aria-disabled", "true"); list.appendChild(empty); return;
      }
      agents.forEach(function (agent) {
        var item = S.node("button", "workbench-agent-launcher-item");
        item.type = "button"; item.setAttribute("role", "menuitem");
        item.appendChild(S.node("span", "workbench-agent-launcher-name", agent.title || agent.providerID || agent.key));
        item.addEventListener("click", function () { setOpen(false); if (options.onPickAgent) options.onPickAgent(agent); });
        list.appendChild(item);
      });
    }
    function setOpen(open) {
      if (open === !menu.hidden) return;
      if (open) renderList();
      menu.hidden = !open; button.setAttribute("aria-expanded", String(open));
      var alignRight = open && menu.getBoundingClientRect && global.innerWidth && menu.getBoundingClientRect().right > global.innerWidth - 8;
      if (menu.classList && menu.classList.toggle) menu.classList.toggle("is-align-right", !!alignRight);
      if (options.onMenuChange) options.onMenuChange(open);
    }
    button.addEventListener("click", function () { setOpen(menu.hidden); });
    if (typeof document !== "undefined" && document.addEventListener) {
      document.addEventListener("click", function (e) { if (!menu.hidden && !root.contains(e.target)) setOpen(false); });
      document.addEventListener("keydown", function (e) {
        if (menu.hidden || e.key !== "Escape") return;
        e.preventDefault(); setOpen(false); if (button.focus) button.focus();
      });
    }
    return { root: root, close: function () { setOpen(false); }, update: function () { if (!menu.hidden) renderList(); } };
  }

  function createAgentDraftView(options) {
    options = options || {};
    var slot = Number.isInteger(options.slot) ? options.slot : 0;
    var draft = { agentKey: options.agentKey || "", projectID: "", input: "", modelID: "", effort: "", permissionMode: "" };
    var pending = null, message = "", lastKey = draft.agentKey, context = { page: null, emit: null };

    var agentField = C().choice("Agent", function (v) {
      draft.agentKey = v; draft.modelID = ""; draft.effort = ""; lastKey = v;
      if (options.onAgentChange) options.onAgentChange(v); syncUI();
    }, "dsh-agent-draft-agent");
    agentField.control.id = "dsh-agent-draft-agent-" + slot;
    var projectField = C().choice("项目", function (v) { draft.projectID = v; syncUI(); }, "dsh-agent-draft-project");
    projectField.control.id = "dsh-agent-draft-project-" + slot; projectField.control.title = "任务所在的项目";
    var switchButton = S.button("改用工作台", null, {}, null, "small dsh-agent-draft-switch");
    switchButton.addEventListener("click", function () { if (options.onSwitchToDSH) options.onSwitchToDSH(); });
    var bar = appendAll(S.node("div", "dsh-agent-draft-bar"), [
      appendAll(S.node("div", "dsh-agent-draft-controls"), [agentField.wrapper, projectField.wrapper]), switchButton
    ]);
    var greetingTitle = S.node("h3", "dsh-chat-empty-title");
    var greeting = appendAll(S.node("div", "dsh-agent-draft-greeting"), [greetingTitle]);
    var thread = S.node("div", "dsh-chat-conversation dsh-agent-draft-thread"); thread.hidden = true;
    var body = appendAll(S.node("div", "dsh-agent-draft-body"), [greeting, thread]);
    var composer = C().create({
      className: "dsh-agent-draft-composer-inner", inputID: "dsh-agent-draft-input-" + slot,
      label: "指令", value: "", placeholder: "描述要让外部 Agent 完成的工作", onSend: submit,
      onPermission: function (v) { draft.permissionMode = v; syncUI(); },
      onModel: function (v) { draft.modelID = v; draft.effort = ""; syncUI(); },
      onEffort: function (v) { draft.effort = v; syncUI(); }
    });
    composer.input.addEventListener("input", function () {
      draft.input = composer.input.value; if (!pending) message = ""; S.autoGrowTextArea(composer.input); validate();
    });
    var composerHost = appendAll(S.node("div", "dsh-agent-draft-composer workbench-controls workbench-pane-composer"), [composer.root]);
    var root = appendAll(S.node("div", "dsh-agent-draft"), [bar, body, composerHost]);

    function selectedAgent() {
      var list = availableAgents();
      return list.find(function (item) { return item.key === draft.agentKey; }) || list[0] || null;
    }
    function targetProject() {
      var page = context.page || {}, projects = S.safeArray(page.projects);
      if (draft.projectID && (!projects.length || projects.some(function (p) { return p.id === draft.projectID; }))) return draft.projectID;
      return S.defaultProjectID(page);
    }
    function permissionMode() {
      if (draft.permissionMode === "read-only" || draft.permissionMode === "full") return draft.permissionMode;
      return context.page && context.page.permissionMode === "read-only" ? "read-only" : "full";
    }
    function blocker() {
      var agent = selectedAgent(), text = composer.input.value;
      if (!targetProject()) return "还没有可用的项目，请先添加工作文件夹。";
      if (!agent) return "暂无可用外部 Agent，请先在连接页启用并连接。";
      if (permissionMode() === "read-only" && agent.readOnly === false) return agent.title + " 仅支持完整权限。";
      if (text.indexOf("\u0000") >= 0 || new TextEncoder().encode(text).length > 32768) return "指令不能包含 NUL，且不能超过 32 KB。";
      return "";
    }
    function validate() {
      var reason = blocker(), busy = !!pending, agent = selectedAgent();
      C().setAction(composer, "send", busy || !!reason || !composer.input.value.trim() || !context.emit);
      composer.action.setAttribute("aria-busy", String(busy));
      [composer.input, agentField.control, projectField.control, composer.model, composer.effort, composer.permission]
        .forEach(function (c) { c.disabled = busy; });
      C().setHint(composer, message || (composer.input.value.trim() ? reason : "") || (agent && agent.errorMessage) || "");
    }
    function updateThread() {
      greeting.hidden = !!pending; thread.hidden = !pending;
      if (!pending) { S.clear(thread); thread.__requestID = null; return; }
      if (thread.__requestID === pending.requestID) return;
      thread.__requestID = pending.requestID; S.clear(thread);
      var conv = global.CodexBridgeDesktopWorkbenchConversation;
      var entry = { id: pending.requestID, messageKey: pending.requestID, kind: "message", role: "用户", text: pending.input, isFinal: true };
      thread.appendChild(conv && conv.createMessage ? conv.createMessage(entry)
        : S.node("div", "conversation-entry entry-message entry-user", entry.text));
      thread.appendChild(S.node("div", "workbench-working-indicator", "正在启动"));
    }
    function syncUI() {
      var list = availableAgents(), agent = selectedAgent(), projects = S.safeArray(context.page && context.page.projects), projectID = targetProject();
      if (agent && !draft.agentKey) draft.agentKey = agent.key;
      forms().selectOptions(agentField.control, list.length
        ? list.map(function (i) { return { id: i.key, title: i.title || i.providerID }; })
        : [{ id: "", title: "暂无可用 Agent" }], false);
      agentField.control.value = agent ? agent.key : "";
      forms().selectOptions(projectField.control, projects.map(function (p) { return { id: p.id, title: p.title }; }), false);
      projectField.control.value = projectID || ""; projectField.wrapper.hidden = !projects.length;
      C().setModels(composer, agent, draft.modelID, draft.effort);
      C().setPermission(composer, permissionMode(), !agent || agent.readOnly !== false);
      var project = projects.find(function (p) { return p.id === projectID; }), name = agent ? (agent.title || agent.providerID) : "外部 Agent";
      greetingTitle.textContent = project ? "在 " + project.title + " 中直接向 " + name + " 发任务" : "直接向 " + name + " 发任务";
      updateThread(); S.autoGrowTextArea(composer.input); validate();
    }
    function submit() {
      if (composer.action.disabled || pending || !context.emit) return;
      var agent = selectedAgent(), projectID = targetProject(), text = composer.input.value;
      if (!agent || !projectID || !text.trim()) return;
      var transport = global.CodexBridgeDesktopEmbeddedDSHTransport;
      var requestID = transport && transport.requestID ? transport.requestID()
        : "dsh-agent-" + Date.now().toString(36) + "-" + Math.random().toString(36).slice(2, 8);
      var payload = { projectID: projectID, input: text, providerID: agent.providerID, installationID: agent.installationID || null,
        modelID: composer.model.value || null, effort: composer.effort.value || null, permissionMode: permissionMode() };
      pending = { requestID: requestID, input: text, providerID: agent.providerID, installationID: agent.installationID || null };
      draft.input = text; message = ""; composer.input.value = "";
      S.autoGrowTextArea(composer.input); syncUI();
      context.emit("submitAgentTask", payload, requestID);
    }
    return {
      root: root, currentProjectID: targetProject, hasPending: function () { return !!pending; },
      focus: function () { if (composer.input && composer.input.focus) global.setTimeout(function () { composer.input.focus(); }, 0); },
      reset: function (nextAgentKey) {
        pending = null; message = ""; draft.input = ""; draft.modelID = ""; draft.effort = ""; draft.permissionMode = "";
        if (nextAgentKey !== undefined) { draft.agentKey = nextAgentKey || ""; lastKey = draft.agentKey; }
        composer.input.value = ""; syncUI();
      },
      update: function (page, emit, agentKey) {
        context.page = page || null; context.emit = emit || null;
        if (agentKey && agentKey !== lastKey) { draft.agentKey = agentKey; draft.modelID = ""; draft.effort = ""; lastKey = agentKey; }
        var receipt = page && page.commandReceipt;
        if (pending && receipt && receipt.command === "submitAgentTask" && receipt.requestID === pending.requestID) {
          var info = { providerID: pending.providerID, installationID: pending.installationID }, sentInput = pending.input;
          pending = null;
          if (receipt.accepted === true) {
            draft.input = ""; message = ""; composer.input.value = ""; syncUI();
            if (options.onAccepted) options.onAccepted(receipt.resultingTaskID || null, info); return;
          }
          draft.input = sentInput; composer.input.value = sentInput; message = receipt.message || "发送失败，请重试。";
        }
        syncUI();
      }
    };
  }

  function createAgentSessionView(options) {
    options = options || {};
    var paneIndex = Number.isInteger(options.paneIndex) ? options.paneIndex : 0;
    var state = { page: null, emit: null, item: null, row: null, detail: null,
      key: "", inputs: null, form: null, following: true, remediationSig: "", sections: null };
    var providerPill = S.node("span", "dsh-external-pane-provider"), statusNode = S.node("span", "dsh-external-pane-status");
    var importSlot = S.node("div", "workbench-import-control dsh-external-pane-import"); importSlot.title = "带入工作台";
    importSlot.addEventListener("pointerdown", function () {
      var imp = global.CodexBridgeDesktopWorkbenchImport;
      if (imp && state.detail) { imp.setActive(true); imp.attach(importSlot, state.detail); }
    });
    var actionsHost = S.node("div", "workbench-task-actions dsh-external-pane-actions");
    var syncDetails = function () {
      var d = global.CodexBridgeDesktopWorkbenchDetails;
      if (d && state.sections && state.detail) d.update(state.sections, state.detail);
    };
    actionsHost.addEventListener("pointerdown", syncDetails); actionsHost.addEventListener("focusin", syncDetails);
    var bar = appendAll(S.node("div", "dsh-external-pane-bar"), [
      appendAll(S.node("div", "dsh-external-pane-meta"), [providerPill, statusNode]),
      appendAll(S.node("div", "dsh-external-pane-controls"), [importSlot, actionsHost])
    ]);
    var remediationHost = S.node("div", "dsh-external-pane-remediation"); remediationHost.hidden = true;
    var card = S.node("div", "task-detail-card dsh-external-pane-card"), emptyNote = S.node("p", "workbench-pane-empty");
    var body = appendAll(S.node("div", "dsh-external-pane-body"), [remediationHost, card, emptyNote]);
    body.addEventListener("scroll", function () { state.following = body.scrollHeight - body.clientHeight - body.scrollTop <= 40; }, { passive: true });
    var composerHost = S.node("div", "dsh-external-pane-composer workbench-controls workbench-pane-composer");
    var root = appendAll(S.node("div", "dsh-external-pane"), [bar, body, composerHost]);

    function resetBody(nextKey) {
      state.key = nextKey; state.inputs = null; state.following = true; state.remediationSig = ""; state.sections = null; state.form = null;
      S.clear(remediationHost); remediationHost.hidden = true; card.__detailHeader = null; card.__conversationContainer = null;
      S.clear(card); S.clear(composerHost);
    }
    function update(item, page, emit) {
      state.item = item || null; state.page = page || null; state.emit = emit || null;
      var tasks = S.safeArray(page && page.tasks);
      var row = (item && item.sessionKey && tasks.find(function (t) { return sessionKey(t) === item.sessionKey; }))
        || (item && item.taskID && tasks.find(function (t) { return t.taskID === item.taskID; })) || null;
      var taskID = (row && row.taskID) || (item && item.taskID) || null;
      var detail = S.safeArray(page && page.paneTasks).find(function (d) { return d && d.taskID === taskID; })
        || (page && page.selectedTask && page.selectedTask.taskID === taskID ? page.selectedTask : null);
      state.row = row; state.detail = detail;
      providerPill.textContent = (detail && detail.provider) || (row && row.provider) || (item && item.provider) || "外部 Agent";
      statusNode.textContent = (detail && detail.status) || (row && row.status) || "";
      root.classList.toggle("is-running", !!((row && row.isRunning) || (detail && detail.isTerminal === false)));
      var imp = global.CodexBridgeDesktopWorkbenchImport;
      if (imp) { if (detail) imp.setActive(true); imp.attach(importSlot, detail); } else importSlot.hidden = true;
      var actions = global.CodexBridgeDesktopWorkbenchActions;
      if (detail && actions) {
        actionsHost.hidden = false;
        actions.render(actionsHost, detail, row || detail, emit, { showDetails: true, queueControl: true, composerControls: true });
      } else actionsHost.hidden = true;
      var nextKey = (row ? sessionKey(row) : (item && item.sessionKey)) || ("t:" + (taskID || ""));
      if (state.key !== nextKey) resetBody(nextKey);
      if (!detail) {
        card.hidden = true; remediationHost.hidden = true; composerHost.hidden = true; emptyNote.hidden = false;
        emptyNote.textContent = tasks.length && !row && item && item.sessionKey && item.sessionKey.indexOf("s:") === 0 ? "找不到此会话。" : "正在载入会话…";
        return;
      }
      emptyNote.hidden = true; card.hidden = false; composerHost.hidden = false;
      var remediation = detail.permissionRemediation || null, remSig = JSON.stringify(remediation);
      if (remSig !== state.remediationSig) {
        state.remediationSig = remSig; S.clear(remediationHost);
        var N = global.CodexBridgeDesktopNativePermissions;
        var remCard = remediation && N && N.remediationCard ? N.remediationCard(detail, emit) : null;
        if (remCard) remediationHost.appendChild(remCard); remediationHost.hidden = !remCard;
      }
      var panePage = buildPanePage(page, detail, row), details = global.CodexBridgeDesktopWorkbenchDetails;
      var sections = details ? details.sections(card) : null;
      state.sections = sections;
      if (details && sections) details.update(sections, detail);
      var conv = global.CodexBridgeDesktopWorkbenchConversation, subs = global.CodexBridgeDesktopWorkbenchSubmissions;
      var inputs = [detail, subs ? subs.revision() : 0, panePage.selectedProjectID,
        !!(page && page.browser && page.browser.canLoadEarlierConversation),
        !!(conv && conv.hasSearchReveal && conv.hasSearchReveal(detail.taskID))];
      if (!sameInputs(state.inputs, inputs) && conv && sections) {
        state.inputs = inputs;
        conv.render(sections.conversation, detail.conversation || [], panePage, emit, { owner: body });
        if (state.following) body.scrollTop = body.scrollHeight;
      }
      var ctrl = global.CodexBridgeDesktopWorkbenchControls, sc = global.CodexBridgeDesktopWorkbenchSessionComposer;
      if (ctrl && sc) {
        if (!state.form || !state.form.__continues(detail)) {
          S.clear(composerHost);
          var hooks = ctrl.paneHooks(function () { return buildPanePage(state.page, state.detail, state.row); }, function () { return state.form; });
          state.form = sc.create(detail, emit, hooks);
          if (state.form.__inputControl) state.form.__inputControl.id = "dsh-external-pane-input-" + paneIndex;
          state.form.querySelectorAll("select").forEach(function (c) { if (c.id === "workbench-steer-mode") c.id = "dsh-external-pane-mode-" + paneIndex; });
          composerHost.appendChild(state.form);
        }
        state.form.__update(detail, panePage, emit);
      }
    }
    return {
      root: root, update: update,
      currentProjectID: function () { return (state.detail && state.detail.projectID) || (state.row && state.row.projectID) || null; },
      currentTaskID: function () { return (state.detail && state.detail.taskID) || (state.row && state.row.taskID) || (state.item && state.item.taskID) || null; },
      matchesComposer: function (pending) {
        return state.form && state.detail && pending && state.form.__continues(pending)
          ? { form: state.form, page: buildPanePage(state.page, state.detail, state.row) } : null;
      },
      focus: function () { var i = state.form && state.form.__inputControl; if (i && !i.disabled && i.focus) global.setTimeout(function () { i.focus(); }, 0); }
    };
  }
  global.CodexBridgeDesktopDSHExternalAgentPane = { sessionKey: sessionKey, createAgentLauncher: createAgentLauncher,
    createAgentDraftView: createAgentDraftView, createAgentSessionView: createAgentSessionView };
}(window));
