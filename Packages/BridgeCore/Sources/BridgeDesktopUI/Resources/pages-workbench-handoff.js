(function (global) {
  "use strict";
  var S = global.CodexBridgeDesktopPageSupport;
  var root = null, currentKey = null, drafts = new Map(), openTasks = new Set();
  var terminalPhases = ["completed", "failed", "interrupted", "target_deleted"];

  function identifier() {
    if (global.crypto && global.crypto.randomUUID) return "handoff-" + global.crypto.randomUUID();
    return "handoff-" + Date.now().toString(36) + "-" + Math.random().toString(36).slice(2)
      + "-" + Math.random().toString(36).slice(2);
  }
  function storageKey(taskID) { return "codex-bridge.handoff.v1." + taskID; }
  function draftFor(taskID) {
    if (drafts.has(taskID)) return drafts.get(taskID);
    var draft = { providerID: "", input: "", preview: null, preparedInput: null,
      operation: null, pending: null, message: "", recovered: false, dirty: false, uncertain: false };
    try {
      var saved = JSON.parse(global.localStorage.getItem(storageKey(taskID)) || "null");
      if (saved && saved.version === 1 && typeof saved.id === "string"
        && /^[a-zA-Z0-9_-]{1,128}$/.test(saved.id) && typeof saved.providerID === "string") {
        draft.operation = { id: saved.id, providerID: saved.providerID,
          sourceUpdatedAt: saved.sourceUpdatedAt || "", submitted: saved.submitted === true };
        draft.providerID = saved.providerID;
        draft.recovered = true;
        draft.message = "发现本机保存的交接记录，请查询状态后继续；不会自动重新执行。";
      }
    } catch (_) { /* No prompt or credential is persisted in browser storage. */ }
    drafts.set(taskID, draft);
    return draft;
  }
  function persist(taskID, draft) {
    if (!draft.operation) return false;
    try {
      var operation = draft.operation;
      var encoded = JSON.stringify({ version: 1, id: operation.id, providerID: operation.providerID,
        sourceUpdatedAt: operation.sourceUpdatedAt, submitted: operation.submitted });
      global.localStorage.setItem(storageKey(taskID), encoded);
      return global.localStorage.getItem(storageKey(taskID)) === encoded;
    } catch (_) { return false; }
  }
  function invalidInput(draft) {
    return draft.input.indexOf("\u0000") >= 0 || new TextEncoder().encode(draft.input).length > 4096;
  }
  function canPrepare(draft) {
    return !draft.pending && (!draft.operation || !draft.operation.submitted
      || (draft.preview && terminalPhases.indexOf(draft.preview.phase) >= 0));
  }
  function canSubmit(detail, draft) {
    return !draft.pending && !draft.uncertain && !invalidInput(draft) && draft.preview && draft.preview.ready === true
      && draft.operation && draft.preview.handoffID === draft.operation.id
      && draft.providerID === draft.operation.providerID && draft.input === draft.preparedInput
      && draft.operation.sourceUpdatedAt === (detail.updatedAt || "");
  }
  function send(action, detail, emit) {
    var draft = draftFor(detail.taskID);
    if (draft.pending) return;
    if (action === "prepare") {
      if (!canPrepare(draft) || invalidInput(draft) || !draft.providerID) return;
      if (draft.operation && draft.operation.submitted
        && !global.confirm("原交接已有接手任务。准备新的交接会在确认后再次执行，是否继续？")) return;
      draft.operation = { id: identifier(), providerID: draft.providerID,
        sourceUpdatedAt: detail.updatedAt || "", submitted: false };
      draft.preview = null;
      draft.preparedInput = null;
      draft.uncertain = false;
    } else if (action === "submit") {
      if (!canSubmit(detail, draft)) return;
      draft.operation.submitted = true;
      draft.uncertain = true;
    } else if (!draft.operation) return;
    if (action !== "status" && !persist(detail.taskID, draft)) {
      if (action === "submit") { draft.operation.submitted = false; draft.uncertain = false; }
      draft.message = "无法保存本机交接恢复标识，已停止发送。请检查应用本地存储。";
      update(detail);
      return;
    }
    var request = identifier(), operation = draft.operation;
    var input = action === "prepare" ? draft.input : "";
    var pending = { requestID: request, action: action, id: operation.id, input: input };
    draft.pending = pending;
    draft.message = action === "prepare" ? "正在生成并校验服务端交接预览…"
      : action === "submit" ? "正在提交已确认的交接版本…" : "正在查询原交接状态…";
    pending.timer = setTimeout(function () {
      if (draft.pending !== pending) return;
      draft.pending = null;
      draft.message = "未收到交接回执；请查询原交接状态，不要把超时当成未执行。";
      if (root && root.__detail && root.__detail.taskID === detail.taskID) update(root.__detail);
    }, 45000);
    if (pending.timer && pending.timer.unref) pending.timer.unref();
    update(detail);
    emit("handoffTask", { taskID: detail.taskID, providerID: operation.providerID, input: input,
      action: action, value: operation.id,
      messageKey: action === "submit" ? draft.preview.revision : null }, request);
  }
  function acknowledge(receipt) {
    if (!receipt || receipt.command !== "handoffTask" || !receipt.taskID) return;
    var draft = drafts.get(receipt.taskID), pending = draft && draft.pending;
    if (!pending || pending.requestID !== receipt.requestID) return;
    clearTimeout(pending.timer);
    draft.pending = null;
    var preview = receipt.handoff;
    if (receipt.accepted !== true || !preview || preview.handoffID !== pending.id
      || preview.sourceTaskID !== receipt.taskID || preview.providerID !== draft.operation.providerID) {
      draft.message = receipt.message || "未获得匹配的交接回执，请查询状态；必要时同步升级 App 与后台服务。";
      return;
    }
    draft.preview = preview;
    draft.uncertain = false;
    draft.preparedInput = preview.additionalInstructions || "";
    if ((pending.action === "prepare" && draft.input === pending.input)
      || (draft.recovered && !draft.dirty)) draft.input = draft.preparedInput;
    draft.recovered = false;
    if (preview.phase === "prepared") draft.operation.submitted = false;
    if (preview.targetTaskID || preview.phase === "submitting") draft.operation.submitted = true;
    draft.message = preview.message || (preview.ready ? "预览已生成；确认后才会启动目标 Agent。" : "交接校验未通过，未启动目标任务。");
    persist(receipt.taskID, draft);
  }
  function ensureRoot() {
    if (root) return;
    var footer = document.getElementById("workbench-inspector-footer");
    if (!footer) return;
    root = S.node("div", "workbench-handoff");
    if (footer.lastChild) footer.insertBefore(root, footer.lastChild); else footer.appendChild(root);
  }
  function render(detail, emit, receipt) {
    acknowledge(receipt);
    ensureRoot();
    if (!root) return;
    if (!detail || !detail.handoffPrompt) { root.hidden = true; currentKey = null; return; }
    var draft = draftFor(detail.taskID), providers = S.safeArray(detail.handoffProviders).slice();
    if (draft.operation && !providers.some(function (p) { return p.id === draft.operation.providerID; })) {
      providers.push({ id: draft.operation.providerID, title: draft.operation.providerID + "（仅恢复交接）" });
    }
    if (!providers.length) { root.hidden = true; return; }
    root.hidden = false;
    root.__detail = detail;
    if (!draft.providerID) draft.providerID = providers[0].id;
    var key = JSON.stringify([detail.taskID, providers]);
    if (key === currentKey) { update(detail); return; }
    currentKey = key;
    S.clear(root);
    var disclosure = S.node("details", "workbench-handoff-details");
    disclosure.open = openTasks.has(detail.taskID);
    disclosure.addEventListener("toggle", function () {
      if (disclosure.open) openTasks.add(detail.taskID); else openTasks.delete(detail.taskID);
    });
    disclosure.appendChild(S.node("summary", null, "交给其他 Agent"));
    var form = S.node("div", "workbench-handoff-form");
    var provider = S.selectField("目标 Agent", draft.providerID, providers, function (value) {
      draft.providerID = value;
      update(root.__detail);
    }, "");
    provider.control.id = "workbench-handoff-provider";
    var input = S.textAreaField("本次交接补充（可选）", draft.input, "补充限制或下一步；原始要求由服务端保留。", "full");
    input.control.id = "workbench-handoff-input";
    input.control.addEventListener("input", function () {
      draft.input = input.control.value;
      draft.dirty = true;
      S.autoGrowTextArea(input.control);
      update(root.__detail);
    });
    var preview = S.node("pre", "workbench-handoff-preview");
    preview.setAttribute("aria-label", "实际发送的交接正文预览");
    var meter = S.node("p", "hint"), warnings = S.node("p", "hint workbench-handoff-warnings");
    var actions = S.node("div", "form-actions");
    var prepare = S.button("生成交接预览", null, {}, null, "small", false);
    var submit = S.button("确认交接", null, {}, null, "small primary", true);
    var query = S.button("查询交接状态", null, {}, null, "small", true);
    var open = S.button("打开接手任务", null, {}, null, "small", true);
    prepare.addEventListener("click", function () { if (!prepare.disabled) send("prepare", root.__detail, emit); });
    submit.addEventListener("click", function () { if (!submit.disabled) send("submit", root.__detail, emit); });
    query.addEventListener("click", function () { if (!query.disabled) send("status", root.__detail, emit); });
    open.addEventListener("click", function () {
      if (!open.disabled && draft.preview) emit("selectTask", { taskID: draft.preview.targetTaskID });
    });
    [prepare, submit, query, open].forEach(function (button) { actions.appendChild(button); });
    var hint = S.node("p", "hint workbench-handoff-hint");
    hint.setAttribute("aria-live", "polite");
    form.appendChild(provider.wrapper); form.appendChild(input.wrapper);
    form.appendChild(preview); form.appendChild(meter); form.appendChild(warnings);
    form.appendChild(actions); form.appendChild(hint); disclosure.appendChild(form); root.appendChild(disclosure);
    root.__input = input.control; root.__provider = provider.control; root.__preview = preview;
    root.__meter = meter; root.__warnings = warnings; root.__hint = hint;
    root.__prepare = prepare; root.__submit = submit; root.__query = query; root.__open = open;
    update(detail);
  }
  function update(detail) {
    if (!root || !root.__submit || !detail || !root.__detail || root.__detail.taskID !== detail.taskID) return;
    var draft = draftFor(detail.taskID), preview = draft.preview, busy = !!draft.pending;
    if (root.__input.value !== draft.input) root.__input.value = draft.input;
    root.__provider.value = draft.providerID;
    var locked = !!draft.operation && draft.operation.submitted && !canPrepare(draft);
    root.__provider.disabled = busy || locked;
    root.__input.disabled = busy || locked;
    root.__prepare.disabled = !canPrepare(draft) || invalidInput(draft) || !draft.providerID;
    root.__submit.disabled = !canSubmit(detail, draft);
    root.__query.disabled = busy || !draft.operation;
    root.__open.disabled = !preview || !preview.targetTaskID || preview.phase === "target_deleted";
    root.__submit.setAttribute("aria-busy", String(busy));
    root.__preview.textContent = preview && preview.prompt ? preview.prompt : "正文由服务端生成；尚未确认时不会启动目标 Agent。";
    root.__meter.textContent = preview ? "目标模型：" + preview.model + "；权限：" + preview.permissionMode
      + "；网络：" + (preview.networkAllowed ? "允许请求" : "未授予")
      + "；正文 " + new TextEncoder().encode(preview.prompt || "").length + " 字节；token 为保守估算，状态：" + preview.phase : "";
    root.__warnings.textContent = preview ? S.safeArray(preview.warnings).join("\n") : "";
    var stale = preview && (!draft.operation || draft.input !== draft.preparedInput
      || draft.providerID !== draft.operation.providerID || draft.operation.sourceUpdatedAt !== (detail.updatedAt || ""));
    root.__hint.textContent = invalidInput(draft) ? "补充内容不能包含 NUL，且不能超过 4096 字节。"
      : stale && !locked ? "来源或补充已变化，请重新生成预览；不会自动覆盖你的补充。" : draft.message;
    S.autoGrowTextArea(root.__input);
  }
  global.CodexBridgeDesktopWorkbenchHandoff = { render: render };
}(window));
