(function (global) {
  "use strict";
  // Lets the user pick a connected Agent and start a task by hand from the web workbench.
  // The greeting sits in the conversation area and the composer in the shared footer,
  // matching the workbench layout. Submission progress shows as the user's message.
  var S = global.CodexBridgeDesktopPageSupport;
  var storageKey = "codexbridge.workbench.new-task.v1", receiptTimeoutMs = 30000;
  var open = false, revision = 0, settingsSignature = "", view = null;
  // A blank split pane can host the draft instead of the inspector: { body, composer }.
  var mount = null;
  var context = { page: null, emit: null, onChange: null, onAccepted: null };
  var pending = null, message = "", receiptTimer = null;
  var draft = { agentKey: "", input: "", modelID: "", effort: "" };
  // The project picked for this draft; empty means the default workspace. Not stored with the draft.
  var projectChoice = "";
  try {
    var saved = JSON.parse(global.localStorage.getItem(storageKey) || "null");
    if (saved && typeof saved === "object") {
      ["agentKey", "input", "modelID", "effort"].forEach(function (key) {
        if (typeof saved[key] === "string") draft[key] = saved[key];
      });
      if (saved.pending && typeof saved.pending.requestID === "string") {
        pending = saved.pending; message = "上次发送未确认，再次发送会沿用同一请求。"; pending.uncertain = true;
      }
    }
  } catch (_) {}

  // Composer and form helpers load after this script, so they are resolved when used.
  function C() { return global.CodexBridgeDesktopWorkbenchComposer; }
  function forms() { return global.CodexBridgeDesktopFormDraft; }
  function persist() {
    try { global.localStorage.setItem(storageKey, JSON.stringify(Object.assign({ pending: pending }, draft))); } catch (_) {}
  }
  function changed() { revision++; }
  // Open state changes re-render the page outside the current render pass.
  function notify() { if (context.onChange) global.setTimeout(context.onChange, 0); }
  function selectedAgent() {
    var list = C().agents();
    return list.find(function (agent) { return agent.key === draft.agentKey; }) || list[0] || null;
  }
  // A task's permission starts from the default for remote clients and can be changed per task.
  function permissionMode() {
    if (draft.permissionMode === "read-only" || draft.permissionMode === "full") return draft.permissionMode;
    return context.page && context.page.permissionMode === "read-only" ? "read-only" : "full";
  }
  function targetProject() {
    var page = context.page || {}, projects = S.safeArray(page.projects);
    var valid = projectChoice && (!projects.length || projects.some(function (item) { return item.id === projectChoice; }));
    return valid ? projectChoice : S.defaultProjectID(page);
  }
  function projectTitle() {
    var id = targetProject();
    var project = S.safeArray((context.page || {}).projects).find(function (item) { return item.id === id; });
    return project ? project.title : "";
  }

  function build() {
    var hero = S.node("section", "workbench-new-task workbench-empty-state");
    hero.setAttribute("aria-label", "新建 Agent 任务");
    var greeting = S.node("div", "workbench-new-task-greeting");
    greeting.appendChild(S.node("h3", "dsh-chat-empty-title"));
    hero.appendChild(greeting);
    var thread = S.node("div", "dsh-chat-conversation workbench-new-task-thread"); thread.hidden = true;
    hero.appendChild(thread);

    var composer = C().create({
      className: "workbench-new-task-composer", inputID: "workbench-new-task-input", label: "指令",
      value: draft.input, placeholder: "描述要让 Agent 完成的工作",
      onSend: submit,
      onPermission: function (value) { draft.permissionMode = value; persist(); update(); },
      onModel: function (value) { draft.modelID = value; draft.effort = ""; persist(); update(); },
      onEffort: function (value) { draft.effort = value; persist(); update(); }
    });
    var agent = C().choice("Agent", function (value) {
      draft.agentKey = value; draft.modelID = ""; draft.effort = ""; persist(); update();
    }, "workbench-new-task-agent");
    agent.control.id = "workbench-new-task-agent";
    composer.leading.insertBefore(agent.wrapper, composer.leading.firstChild);
    var project = C().choice("项目", function (value) { projectChoice = value; update(); }, "workbench-composer-project");
    project.control.id = "workbench-new-task-project"; project.control.title = "任务所在的项目";
    composer.leading.appendChild(project.wrapper);
    composer.input.addEventListener("input", function () {
      draft.input = composer.input.value; if (!pending) message = "";
      persist(); S.autoGrowTextArea(composer.input); validate();
    });
    composer.root.hidden = true;
    return { hero: hero, title: greeting.firstChild, greeting: greeting, thread: thread, composer: composer,
      agent: agent.control, project: project.control, projectWrapper: project.wrapper };
  }

  function ensureView() {
    if (!view) view = build();
    var host = mount ? mount.composer : document.getElementById("workbench-inspector-footer");
    if (host && view.composer.root.parentNode !== host) host.appendChild(view.composer.root);
    view.composer.root.hidden = !open && !mount;
    return view;
  }

  function update() {
    if (!view) return;
    var list = C().agents(), agent = selectedAgent(), composer = view.composer;
    forms().selectOptions(view.agent, list.length ? list.map(function (item) { return { id: item.key, title: item.title }; })
      : [{ id: "", title: "暂无可用 Agent" }], false);
    view.agent.value = agent ? agent.key : "";
    var projects = S.safeArray((context.page || {}).projects);
    forms().selectOptions(view.project, projects.map(function (item) { return { id: item.id, title: item.title }; }), false);
    view.project.value = targetProject() || "";
    view.projectWrapper.hidden = projects.length < 2;
    C().setModels(composer, agent, draft.modelID, draft.effort);
    C().setPermission(composer, permissionMode(), !agent || agent.readOnly);
    if (composer.input.value !== draft.input && document.activeElement !== composer.input) composer.input.value = draft.input;
    var project = projectTitle();
    view.title.textContent = project ? "想让 Agent 在 " + project + " 中完成什么？" : "想让 Agent 完成什么？";
    updateThread();
    S.autoGrowTextArea(composer.input);
    validate();
  }

  // While the task is being created the user's message is already shown, like a native chat.
  function updateThread() {
    var sending = !!pending && !pending.uncertain && pending.payload;
    view.greeting.hidden = !!sending; view.thread.hidden = !sending;
    view.hero.classList.toggle("is-sending", !!sending);
    if (!sending) { S.clear(view.thread); view.threadKey = null; return; }
    if (view.threadKey === pending.requestID) return;
    view.threadKey = pending.requestID; S.clear(view.thread);
    var conversation = global.CodexBridgeDesktopWorkbenchConversation;
    var entry = { id: pending.requestID, messageKey: pending.requestID, kind: "message", role: "用户",
      text: pending.payload.input, isFinal: true };
    view.thread.appendChild(conversation && conversation.createMessage ? conversation.createMessage(entry)
      : S.node("div", "conversation-entry entry-message entry-user", entry.text));
    view.thread.appendChild(S.node("div", "workbench-working-indicator", "正在启动"));
  }

  function blocker() {
    var agent = selectedAgent(), text = view.composer.input.value;
    if (!targetProject()) return "还没有可用的项目，请先添加工作文件夹。";
    if (!agent) return "暂无可用 Agent，请先在连接页启用并连接。";
    if (permissionMode() === "read-only" && !agent.readOnly) return agent.title + " 仅支持完整权限。";
    if (text.indexOf("\u0000") >= 0 || new TextEncoder().encode(text).length > 32768) return "指令不能包含 NUL，且不能超过 32 KB。";
    return "";
  }
  function validate() {
    if (!view) return;
    var composer = view.composer, reason = blocker(), busy = !!pending && !pending.uncertain;
    C().setAction(composer, "send", busy || !!reason || !composer.input.value.trim() || !context.emit);
    composer.action.setAttribute("aria-busy", String(busy));
    [composer.input, view.agent, view.project, composer.model, composer.effort].forEach(function (control) { control.disabled = busy; });
    // Only problems the user must act on are shown below the composer.
    var typed = !!composer.input.value.trim();
    C().setHint(composer, message || (typed ? reason : "") || (selectedAgent() && selectedAgent().errorMessage) || "");
  }

  function submit() {
    if (!view || view.composer.action.disabled) return;
    var agent = selectedAgent(), composer = view.composer;
    var payload = { projectID: targetProject(), providerID: agent.providerID, input: composer.input.value,
      modelID: composer.model.value || null, effort: composer.effort.value || null, permissionMode: permissionMode() };
    if (agent.installationID) payload.installationID = agent.installationID;
    // An unconfirmed request is resent with its original ID so the service can deduplicate it.
    var reuse = pending && pending.uncertain && JSON.stringify(pending.payload) === JSON.stringify(payload);
    pending = { requestID: reuse ? pending.requestID : global.CodexBridgeDesktopWorkbenchSubmissions.newRequestID(),
      payload: payload };
    message = ""; persist();
    composer.input.value = ""; S.autoGrowTextArea(composer.input);
    updateThread(); validate();
    if (receiptTimer) global.clearTimeout(receiptTimer);
    receiptTimer = global.setTimeout(function () {
      if (!pending) return;
      pending.uncertain = true; persist();
      message = "发送未确认，请先在会话列表核对；再次发送会沿用同一请求。";
      restoreInput(); updateThread(); validate();
    }, receiptTimeoutMs);
    context.emit("submitAgentTask", payload, pending.requestID);
  }
  function restoreInput() {
    if (view && !view.composer.input.value) { view.composer.input.value = draft.input; S.autoGrowTextArea(view.composer.input); }
  }

  function acknowledge(page) {
    var receipt = page && page.commandReceipt;
    if (!pending || !receipt || receipt.command !== "submitAgentTask" || receipt.requestID !== pending.requestID) return;
    if (receiptTimer) { global.clearTimeout(receiptTimer); receiptTimer = null; }
    if (receipt.accepted === true) {
      var taskID = receipt.resultingTaskID;
      pending = null; message = ""; draft.input = ""; delete draft.permissionMode; projectChoice = ""; persist();
      if (view) { view.composer.input.value = ""; updateThread(); }
      if (context.onAccepted) context.onAccepted(taskID || null);
      api.close();
      if (taskID && context.emit) context.emit("selectTask", { taskID: taskID });
      return;
    }
    // A rejected request never reached execution, so a new attempt gets a fresh request ID.
    pending = null; persist();
    message = receipt.message || "发送失败，请检查后重试。";
    restoreInput();
    if (view) updateThread();
    validate();
  }

  var api = {
    isOpen: function () { return open; },
    owns: function (node) { return !!view && node === view.hero; },
    revision: function () { return revision; },
    // `options.projectID` starts the draft in that project, otherwise the current choice stays.
    open: function (options) {
      if (options && options.projectID) { projectChoice = options.projectID; changed(); if (view && open) update(); }
      if (!open) { open = true; changed(); notify(); }
      global.setTimeout(function () { if (view && open) view.composer.input.focus(); }, 0);
    },
    close: function () {
      if (!open) return;
      open = false; changed(); notify();
    },
    // Closing the draft tab discards its text unless a submission is still awaiting a receipt.
    discard: function () {
      if (!pending) { draft.input = ""; delete draft.permissionMode; message = ""; projectChoice = ""; persist(); if (view) view.composer.input.value = ""; }
      api.close();
    },
    setSettings: function (value) {
      var settings = value || null;
      C().setSettings(settings);
      var signature = JSON.stringify([settings && settings.models, settings && settings.executionModel,
        settings && settings.executionEffort, settings && settings.agentDefaults]);
      if (signature !== settingsSignature) { settingsSignature = signature; changed(); }
    },
    setOnChange: function (handler) { context.onChange = handler; },
    setOnAccepted: function (handler) { context.onAccepted = handler; },
    receive: function (page, emit) {
      context.page = page; context.emit = emit;
      acknowledge(page);
      ensureView();
      if (open || mount) update();
    },
    // Shows the draft in a blank split pane; `unmount` returns it to the inspector.
    mount: function (body, composerHost, page, emit) {
      context.page = page; context.emit = emit;
      mount = { body: body, composer: composerHost };
      ensureView();
      if (view.hero.parentNode !== body) body.appendChild(view.hero);
      update();
    },
    unmount: function () {
      if (!mount) return;
      if (view && view.hero.parentNode === mount.body) view.hero.remove();
      mount = null;
      if (view) ensureView();
    },
    render: function (container, page, emit) {
      context.page = page; context.emit = emit;
      ensureView();
      if (view.hero.parentNode !== container) container.appendChild(view.hero);
      update();
    }
  };
  global.CodexBridgeDesktopWorkbenchNewTask = api;
}(window));
