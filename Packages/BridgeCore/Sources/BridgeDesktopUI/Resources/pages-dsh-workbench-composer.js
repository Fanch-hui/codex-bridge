(function (global) {
  "use strict";
  var S = global.CodexBridgeDesktopPageSupport, D = global.CodexBridgeDesktopFormDraft;
  var P = global.CodexBridgeDesktopWorkbenchSubmissions, V = global.CodexBridgeDesktopDSHComposerView;
  var key = "codexbridge.dsh.new-session.v1";
  function readDraft() {
    try { return JSON.parse(global.localStorage.getItem(key) || "null") || {}; } catch (_) { return {}; }
  }
  function create(onAccepted) {
    var saved = readDraft(), context = {}, draftKey = null, pending = saved.pending || null;
    var drafts = saved.drafts || {}, queries = {}, recovered = !!pending, receiptTimer = null;
    var rejected = !!(pending && pending.canEditInput), message = pending ? "提交未确认，请恢复提交。" : "";
    var view = V.create(), attachmentDraft = { attachmentPaths: [], attachmentError: "" };
    var attachments = null, attachmentSignature = null, composing = false, deferredUpdate = null;
    function forward(command, payload) { if (context.emit) context.emit(command, payload); }
    function persist() {
      try { global.localStorage.setItem(key, JSON.stringify({ drafts: drafts, pending: pending })); } catch (_) {}
    }
    function detail() { return context.page && context.page.selectedTask || {}; }
    function running() { return detail().canSteer === true || detail().canStop === true; }
    function currentDraft() { return drafts[draftKey] || (drafts[draftKey] = {}); }
    function saveInput() {
      if (!draftKey || pending) return;
      drafts[draftKey] = { input: view.input.value, modelID: view.model.value, effort: view.effort.value,
        mode: view.mode.value, attachmentPaths: attachmentDraft.attachmentPaths.slice() };
      persist();
    }
    function selectedModel() {
      var item = context.item || {}, id = view.model.value || item.model;
      return S.safeArray(item.modelOptions).find(function (value) { return id ? value.modelID === id : value.isDefaultModel; });
    }
    function efforts(desired) {
      var item = context.item || {}, selected = selectedModel();
      var choices = selected && Array.isArray(selected.reasoningEfforts) ? selected.reasoningEfforts
        : view.model.value === (item.model || "") ? S.safeArray(item.effortOptions) : [];
      var task = detail(), options = choices.filter(function (choice) { return choice.id; });
      if (!task.taskID || item.effort) options.unshift({ id: "", title: "默认强度" });
      var current = desired == null ? view.effort.value : desired;
      if (!current && options.length && !options.some(function (choice) { return choice.id === ""; })) {
        var preferred = selected && selected.defaultReasoningEffort;
        current = options.some(function (choice) { return choice.id === preferred; }) ? preferred : options[0].id;
      }
      D.selectOptions(view.effort, S.choices(current, options), false); view.effort.value = current || "";
      view.effortWrapper.hidden = options.length === 0 || selected && selected.reasoningCapabilitiesAvailable === false;
      view.effort.disabled = !!pending || running() || choices.length === 0
        || selected && selected.reasoningCapabilitiesAvailable === false;
    }
    function canAttachImages() {
      var choice = selectedModel();
      return !!choice && S.safeArray(choice.inputModalities).indexOf("image") >= 0;
    }
    function queryCapabilities() {
      var item = context.item || {}, page = context.page || {}, choice = selectedModel();
      var id = view.model.value || item.model || choice && choice.modelID;
      if (pending || running() || !id || !page.selectedProjectID || !item.installationID || !context.emit
        || item.isRefreshingModels || item.canSave !== true || choice && Array.isArray(choice.inputModalities)) return;
      var scope = JSON.stringify([page.selectedProjectID, item.installationID, id]);
      if (queries[scope]) return;
      queries[scope] = true;
      context.emit("refreshAgentModels", { providerID: "deepseek-harness", installationID: item.installationID, modelID: id });
    }
    function addAttachment(projectID, path) {
      if (pending || running() || projectID !== (context.page || {}).selectedProjectID || !canAttachImages()
        || typeof path !== "string" || !/\.(png|jpe?g|webp)$/i.test(path)) return false;
      if (attachmentDraft.attachmentPaths.indexOf(path) >= 0) return true;
      if (attachmentDraft.attachmentPaths.length >= 8) return false;
      attachmentDraft.attachmentPaths.push(path); attachmentDraft.attachmentError = "";
      saveInput(); validate(); return true;
    }
    function updateAttachments() {
      var allowed = canAttachImages(), signature = JSON.stringify([draftKey, allowed, !!attachmentDraft.attachmentPaths.length]);
      if (signature !== attachmentSignature) {
        attachmentSignature = signature;
        attachments = V.attachments(view.attachmentSlot, attachmentDraft, allowed, function () { saveInput(); validate(); });
      }
      if (attachments) { attachments.update(); attachments.setDisabled(!!pending || running()); }
    }
    function validate() {
      var page = context.page || {}, item = context.item || {}, task = detail();
      var invalid = view.input.value.indexOf("\u0000") >= 0 || new TextEncoder().encode(view.input.value).length > 32768;
      var ready = !!page.selectedProjectID && !!item.installationID && item.canSave === true
        && (!task.installationID || task.installationID === item.installationID);
      var active = running();
      var blocked = !!pending || !!task.taskID && P.isPending(task.taskID)
        || !!page.awaitingTaskID && page.awaitingTaskID !== task.taskID;
      var unavailable = !!task.taskID && !task.canResume && !task.canSteer;
      var invalidAttachments = !!attachmentDraft.attachmentError
        || attachmentDraft.attachmentPaths.length > 0 && (active || !canAttachImages());
      updateAttachments();
      view.send.disabled = blocked || !ready || unavailable || !view.input.value.trim() || invalid || invalidAttachments;
      view.send.setAttribute("aria-busy", String(blocked)); view.input.disabled = blocked;
      view.model.disabled = blocked || active || !ready || item.canSelectModel === false;
      view.recover.hidden = !pending || !recovered;
      view.edit.hidden = !pending || !rejected || pending.draftKey !== draftKey;
      view.recover.disabled = !pending || !context.emit; view.recovery.hidden = view.recover.hidden && view.edit.hidden;
      view.stop.hidden = task.canStop !== true; view.stop.disabled = !context.emit;
      view.modeWrapper.hidden = !task.canSteer || S.safeArray(page.steerModes).length < 2;
      view.mode.disabled = blocked; view.input.setAttribute("aria-invalid", String(invalid));
      view.hint.textContent = message || (invalidAttachments ? attachmentDraft.attachmentError
        || (active ? "运行中只能发送文字。" : canAttachImages() ? "图片路径不可用。"
          : selectedModel() && Array.isArray(selectedModel().inputModalities) ? "当前模型不支持图片。" : item.errorMessage || "正在确认图片能力…")
        : invalid ? "消息不能包含 NUL，且不能超过 32768 字节。" : !page.selectedProjectID ? "请选择项目。"
        : !ready ? "请在引擎设置连接 DSH ACP。"
        : unavailable ? "此会话暂时不能发送消息。" : "");
      view.hint.hidden = !view.hint.textContent; efforts();
    }
    function emitPending() {
      if (receiptTimer) clearTimeout(receiptTimer);
      message = "正在确认提交…"; recovered = rejected = false;
      delete pending.canEditInput; persist();
      receiptTimer = setTimeout(function () {
        if (!pending) return;
        recovered = true; message = "提交未确认，可恢复原请求。"; validate();
      }, 15000);
      if (receiptTimer && receiptTimer.unref) receiptTimer.unref();
      validate(); context.emit("submitDSHTask", pending.payload, pending.requestID);
    }
    function submit() {
      if (view.send.disabled || pending) return;
      saveInput(); var task = detail(), input = view.input.value, requestID = P.newRequestID();
      if (task.taskID) { submitExisting(task, input, requestID); return; }
      pending = { requestID: requestID, draftKey: draftKey, payload: {
        projectID: context.page.selectedProjectID, installationID: context.item.installationID,
        input: input, modelID: view.model.value || null, effort: view.effort.value || null,
        permissionMode: "full", queueIfBusy: true } };
      if (attachmentDraft.attachmentPaths.length) pending.payload.attachmentPaths = attachmentDraft.attachmentPaths.slice();
      P.begin(context.page, { command: "submitDSHTask", requestID: requestID, input: input });
      view.input.value = ""; persist(); emitPending();
    }
    function submitExisting(task, input, requestID) {
      var command = task.canSteer ? "steerTask" : "resumeTask", payload = { taskID: task.taskID, input: input };
      if (command === "steerTask") payload.mode = view.mode.value || "queued";
      else {
        payload.queueIfBusy = true;
        payload.executionSelection = { modelID: view.model.value || null, effort: view.effort.value || null,
          permissionMode: "full" };
        if (attachmentDraft.attachmentPaths.length) payload.attachmentPaths = attachmentDraft.attachmentPaths.slice();
      }
      P.begin(context.page, { command: command, requestID: requestID, taskID: task.taskID, input: input,
        mode: payload.mode, draftKey: draftKey, attachmentPaths: attachmentDraft.attachmentPaths.slice() });
      view.input.value = ""; attachmentDraft.attachmentPaths = []; saveInput(); validate();
      context.emit(command, payload, requestID);
    }
    function acknowledge(page) {
      var previous = P.acknowledge(page);
      if (previous && previous.state === "failed") {
        if (typeof previous.input === "string" && previous.draftKey) {
          var draft = drafts[previous.draftKey] || (drafts[previous.draftKey] = {});
          if (!draft.input) { draft.input = previous.input; draft.attachmentPaths = previous.attachmentPaths || []; }
          if (draftKey === previous.draftKey && !view.input.value) {
            view.input.value = draft.input; attachmentDraft.attachmentPaths = draft.attachmentPaths.slice();
          }
        }
        message = previous.message || "发送失败，请重试。"; persist();
      }
      var receipt = page && page.commandReceipt;
      if (!pending || !receipt || receipt.requestID !== pending.requestID || receipt.command !== "submitDSHTask") return;
      if (receipt.accepted === true && receipt.resultingTaskID) {
        var taskID = receipt.resultingTaskID, original = drafts[pending.draftKey];
        if (original && original.input === pending.payload.input) { original.input = ""; original.attachmentPaths = []; }
        if (draftKey === pending.draftKey) { view.input.value = ""; attachmentDraft.attachmentPaths = []; attachmentDraft.attachmentError = ""; }
        if (receiptTimer) clearTimeout(receiptTimer);
        pending = null; message = ""; persist();
        context.emit("selectTask", { taskID: taskID }); if (onAccepted) onAccepted(taskID); return taskID;
      }
      if (receipt.accepted === false) {
        if (receiptTimer) clearTimeout(receiptTimer);
        message = receipt.message || "提交失败，请恢复原请求。"; recovered = true;
        rejected = receipt.canEditInput === true; pending.canEditInput = rejected; persist();
      }
    }
    view.input.addEventListener("input", function () { message = ""; saveInput(); S.autoGrowTextArea(view.input); validate(); });
    view.input.addEventListener("compositionstart", function () { composing = true; });
    view.input.addEventListener("compositionend", function () {
      composing = false; saveInput();
      if (deferredUpdate) { var next = deferredUpdate; deferredUpdate = null; update(next[0], next[1], next[2]); }
    });
    view.model.addEventListener("change", function () {
      var choice = selectedModel(); efforts(choice && choice.defaultReasoningEffort || ""); saveInput(); queryCapabilities(); validate();
    });
    view.effort.addEventListener("change", saveInput); view.mode.addEventListener("change", saveInput);
    view.send.addEventListener("click", submit);
    view.stop.addEventListener("click", function () { if (detail().canStop) forward("stopTask", { taskID: detail().taskID }); });
    view.recover.addEventListener("click", function () { if (pending && recovered) emitPending(); });
    view.edit.addEventListener("click", function () {
      if (!rejected) return;
      var input = pending.payload.input; pending = null; recovered = rejected = false; message = "";
      view.input.value = input; saveInput(); persist(); validate(); view.input.focus();
    });
    view.input.addEventListener("keydown", function (event) {
      if (event.key === "Enter" && !event.shiftKey && !event.isComposing && !composing) { event.preventDefault(); submit(); }
    });
    function update(page, settings, emit) {
      var task = page && page.selectedTask || {};
      var item = S.safeArray(settings && settings.agentDefaults).find(function (value) {
        return value.providerID === "deepseek-harness";
      }) || {};
      var installationID = task.installationID || item.installationID;
      var nextKey = task.taskID ? JSON.stringify([page.selectedProjectID, installationID, task.taskID])
        : JSON.stringify([page && page.selectedProjectID, installationID]);
      if (composing && nextKey !== draftKey) { deferredUpdate = [page, settings, emit]; return; }
      if (nextKey !== draftKey) saveInput();
      context = { page: page, item: item, emit: emit };
      var openedTaskID = acknowledge(page);
      if (openedTaskID) context.page = Object.assign({}, page, { awaitingTaskID: openedTaskID });
      var desiredModel = view.model.value, desiredEffort = view.effort.value;
      if (nextKey !== draftKey) {
        draftKey = nextKey; message = pending ? message : ""; var draft = currentDraft();
        view.input.value = pending && pending.draftKey === draftKey ? "" : draft.input || "";
        desiredModel = draft.modelID == null ? task.executionModel || item.model || "" : draft.modelID;
        desiredEffort = draft.effort == null ? Object.prototype.hasOwnProperty.call(task, "executionEffort")
          ? task.executionEffort || "" : item.effort || "" : draft.effort;
        attachmentDraft.attachmentPaths = S.safeArray(draft.attachmentPaths).slice(); attachmentDraft.attachmentError = "";
      }
      var modelOptions = global.CodexBridgeDesktopSettingsModels.modelChoices(item.modelOptions);
      if (!task.taskID) modelOptions.unshift({ id: "", title: "默认模型" });
      D.selectOptions(view.model, S.choices(desiredModel, modelOptions), false);
      view.model.value = desiredModel; efforts(desiredEffort);
      var modes = S.safeArray(page.steerModes).filter(function (choice) { return choice.enabled !== false; });
      if (!modes.length) modes = [{ id: "queued", title: "结束后发送" }];
      var desiredMode = currentDraft().mode || "queued";
      if (!modes.some(function (choice) { return choice.id === desiredMode; })) desiredMode = modes[0].id;
      D.selectOptions(view.mode, modes, false); view.mode.value = desiredMode;
      queryCapabilities(); validate(); S.autoGrowTextArea(view.input);
    }
    return { root: view.root, update: update, addAttachment: addAttachment,
      focus: function () { view.input.focus(); },
      pendingMessage: function () {
        return pending && pending.draftKey === draftKey ? {
          id: "submission:" + pending.requestID, role: "用户", kind: "message", text: pending.payload.input,
          isFinal: true, deliveryState: rejected ? "failed" : "sending", deliveryMessage: message
        } : null;
      } };
  }
  global.CodexBridgeDesktopDSHComposer = { create: create };
}(window));
