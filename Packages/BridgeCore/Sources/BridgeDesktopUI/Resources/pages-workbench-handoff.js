(function (global) {
  "use strict";

  var S = global.CodexBridgeDesktopPageSupport;
  var root = null, footer = null, status = null, currentKey = null;
  var drafts = new Map(), pending = null, openTasks = new Set();

  function requestID() {
    return "handoff-" + Date.now().toString(36) + "-" + Math.random().toString(36).slice(2, 10);
  }

  function ensureRoot() {
    if (root) return;
    footer = document.getElementById("workbench-inspector-footer");
    status = footer && footer.lastChild;
    root = S.node("div", "workbench-handoff");
    root.hidden = true;
    if (status && status.parentNode === footer) footer.insertBefore(root, status);
    else if (footer) footer.appendChild(root);
  }

  function draftFor(taskID, prompt) {
    if (!drafts.has(taskID)) drafts.set(taskID, { providerID: "", input: prompt || "" });
    var draft = drafts.get(taskID);
    if (!draft.input && prompt) draft.input = prompt;
    return draft;
  }

  function acknowledge(detail, receipt) {
    if (!pending || !receipt || receipt.command !== "handoffTask"
      || receipt.requestID !== pending.requestID || receipt.taskID !== pending.taskID
      || (receipt.input == null ? null : receipt.input) !== pending.input) return;
    var taskID = pending.taskID, draft = draftFor(taskID, detail && detail.handoffPrompt);
    var accepted = receipt.accepted === true;
    pending = null;
    if (accepted && draft.input === receipt.input) {
      draft.input = "";
      if (root && root.__input) {
        root.__input.value = "";
        S.autoGrowTextArea(root.__input);
      }
    }
    validate(detail);
  }

  function render(detail, emit, receipt) {
    ensureRoot();
    acknowledge(detail, receipt);
    if (!detail || !detail.handoffPrompt || !S.safeArray(detail.handoffProviders).length) {
      root.hidden = true;
      currentKey = null;
      return;
    }
    root.hidden = false;
    var providers = S.safeArray(detail.handoffProviders);
    var key = JSON.stringify([detail.taskID, detail.handoffPrompt, providers]);
    if (key === currentKey) {
      validate(detail);
      return;
    }
    currentKey = key;
    var draft = draftFor(detail.taskID, detail.handoffPrompt);
    var providerID = providers.some(function (choice) {
      return choice.id === draft.providerID && choice.enabled !== false;
    }) ? draft.providerID : (providers.find(function (choice) {
      return choice.enabled !== false;
    }) || providers[0]).id;
    draft.providerID = providerID;
    S.clear(root);
    var disclosure = S.node("details", "workbench-handoff-details");
    disclosure.open = openTasks.has(detail.taskID);
    disclosure.addEventListener("toggle", function () {
      if (disclosure.open) openTasks.add(detail.taskID); else openTasks.delete(detail.taskID);
    });
    disclosure.appendChild(S.node("summary", null, "交给其他 Agent"));
    var form = S.node("div", "workbench-handoff-form");
    var provider = S.selectField("目标 Agent", providerID, providers, function (value) {
      draft.providerID = value;
      validate(detail);
    }, "");
    provider.control.id = "workbench-handoff-provider";
    var input = S.textAreaField("交接内容", draft.input, "检查并编辑要交给目标 Agent 的摘要…", "full");
    input.control.id = "workbench-handoff-input";
    input.control.setAttribute("aria-label", "交接内容");
    input.control.addEventListener("input", function () {
      draft.input = input.control.value;
      S.autoGrowTextArea(input.control);
      validate(detail);
    });
    S.autoGrowTextArea(input.control);
    var actions = S.node("div", "form-actions");
    var confirm = S.button("确认交接", null, {}, null, "small primary", false);
    confirm.addEventListener("click", function () {
      if (confirm.disabled) return;
      var request = requestID(), value = input.control.value;
      pending = {
        requestID: request, taskID: detail.taskID, input: value,
        baselineReceiptID: receipt && receipt.receiptID
      };
      validate(detail);
      emit("handoffTask", { taskID: detail.taskID, providerID: provider.control.value, input: value }, request);
    });
    actions.appendChild(confirm);
    var hint = S.node("p", "hint workbench-handoff-hint", "提交前可编辑交接摘要；原会话记录会保留。 ");
    form.appendChild(provider.wrapper); form.appendChild(input.wrapper); form.appendChild(actions); form.appendChild(hint);
    disclosure.appendChild(form); root.appendChild(disclosure);
    root.__input = input.control; root.__provider = provider.control; root.__confirm = confirm;
    root.__hint = hint; root.__detail = detail;
    validate(detail);
  }

  function validate(detail) {
    if (!root || !root.__confirm || !detail) return;
    var input = root.__input.value, invalid = input.indexOf("\u0000") >= 0
      || new TextEncoder().encode(input).length > 32768;
    var busy = !!pending && pending.taskID === detail.taskID;
    root.__confirm.disabled = busy || !root.__provider.value || !input.trim() || invalid;
    root.__confirm.setAttribute("aria-busy", String(busy));
    root.__confirm.setAttribute("data-pending", String(busy));
    root.__hint.textContent = invalid ? "交接内容不能包含 NUL 字符，且不能超过 32768 字节。" : "提交前可编辑交接摘要；原会话记录会保留。";
  }

  global.CodexBridgeDesktopWorkbenchHandoff = { render: render };
}(window));
