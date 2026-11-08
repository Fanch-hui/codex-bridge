(function (global) {
  "use strict";
  var S = global.CodexBridgeDesktopPageSupport;
  function button(title, action) {
    var value = S.button(title, null, {}, null, "small");
    value.addEventListener("click", action); return value;
  }

  function create(options) {
    var id = options.id, state = options.state;
    var itemButton = S.button("", null, {}, null, "dsh-embedded-agent-item");
    var label = S.node("span", "dsh-embedded-agent-title"), status = S.node("span", "dsh-embedded-agent-status hint");
    var chevron = S.node("span", "dsh-embedded-agent-chevron", "›");
    chevron.setAttribute("aria-hidden", "true");
    itemButton.appendChild(label); itemButton.appendChild(status); itemButton.appendChild(chevron);
    itemButton.addEventListener("click", function () { options.open(); });

    var detail = S.node("section", "dsh-embedded-agent-session"); detail.hidden = true;
    var header = S.node("header", "dsh-embedded-agent-header");
    var back = button("‹ 返回", function () { options.close(); });
    back.classList.add("dsh-embedded-agent-back");
    back.setAttribute("aria-label", "返回 Agent 列表");
    var detailLabel = S.node("span", "dsh-embedded-agent-detail-title");
    var detailStatus = S.node("span", "dsh-embedded-agent-status hint");
    header.appendChild(back); header.appendChild(detailLabel); header.appendChild(detailStatus);
    detail.appendChild(header);

    var workspaceReason = S.node("p", "hint dsh-embedded-agent-hint"); workspaceReason.hidden = true;
    detail.appendChild(workspaceReason);
    var changes = S.node("details", "dsh-embedded-agent-changes"); changes.hidden = true;
    var changesSummary = S.node("summary", null, "文件变更"), changesContent = S.node("pre", "mono");
    changes.appendChild(changesSummary); changes.appendChild(changesContent); detail.appendChild(changes);
    var repair = button("交给 Agent 处理", function () {
      var row = result;
      if (!options.isCurrent(row) || !row.canRepair || state.sendID || state.stopID) return;
      var paths = row.conflicts.length ? "\n冲突文件：\n" + row.conflicts.join("\n") : "";
      options.submit("send", "请在当前副本中处理合并冲突，结合两侧改动保留正确行为，移除所有冲突标记，并完成必要验证。" + paths,
        null, { preserveDraft: true, repairConflict: true });
    });
    repair.hidden = true; detail.appendChild(repair);
    var recovery = button("查看恢复", function () { if (options.openRecovery) options.openRecovery(); });
    recovery.hidden = true; detail.appendChild(recovery);

    var body = S.node("div", "dsh-embedded-agent-body"); detail.appendChild(body);
    var history = global.CodexBridgeDesktopEmbeddedDSHConversation.create({ contextSettings: false });
    var historyStatus = S.node("p", "hint dsh-embedded-agent-hint"); historyStatus.hidden = true;
    body.appendChild(historyStatus); body.appendChild(history.root);

    var compose = S.node("div", "dsh-embedded-agent-compose");
    var field = S.textField("给子智能体发送消息", "", "输入补充任务");
    var fieldLabel = field.wrapper.querySelector("label");
    if (fieldLabel) fieldLabel.hidden = true;
    field.control.setAttribute("aria-label", "给子智能体发送消息");
    compose.appendChild(field.wrapper);
    var actions = S.node("div", "form-actions dsh-embedded-agent-actions");
    var feedback = S.node("p", "hint dsh-embedded-agent-feedback");
    feedback.setAttribute("role", "status"); feedback.hidden = true;
    field.control.value = state.text || "";
    field.control.addEventListener("input", function () { state.text = field.control.value; state.feedback = ""; options.save(); });
    var send = button("发送", function () {
      var text = field.control.value;
      if (!text.trim()) return;
      state.text = text; options.submit("send", text, state.delivery);
    });
    field.control.addEventListener("keydown", function (event) {
      if (event.key === "Enter" && !event.shiftKey && !global.CodexBridgeDesktopPageSupport.isIMEKeyEvent(event)) {
        event.preventDefault();
        if (!send.disabled) send.click();
      }
    });
    var stop = button("停止", function () { options.submit("stop", ""); });
    var delivery = S.node("select"); delivery.setAttribute("aria-label", "发送方式");
    delivery.addEventListener("change", function () { state.delivery = delivery.value; options.save(); syncControls(); });
    actions.appendChild(delivery); actions.appendChild(send); actions.appendChild(stop); compose.appendChild(actions); compose.appendChild(feedback);
    detail.appendChild(compose);

    function syncControls() {
      var caps = result.capabilities || {}, choices = [];
      if (caps.canSteer) choices.push({ id: "steer", title: "立即插入" });
      if (caps.canQueue) choices.push({ id: "queue", title: "排队发送" });
      if (caps.canContinue) choices.push({ id: "continue", title: "发送" });
      if (caps.canSend && !choices.length) choices.push({ id: "", title: "发送" });
      if (!choices.some(function (choice) { return choice.id === state.delivery; })) state.delivery = choices.length ? choices[0].id : "";
      var signature = JSON.stringify(choices);
      if (delivery.__signature !== signature) {
        delivery.__signature = signature; S.clear(delivery);
        choices.forEach(function (choice) {
          var option = S.node("option", null, choice.title); option.value = choice.id; delivery.appendChild(option);
        });
      }
      delivery.value = state.delivery; delivery.hidden = choices.length < 2;
      delivery.disabled = !!state.sendID || !!state.stopID;
      repair.disabled = !!state.sendID || !!state.stopID;
      if (!state.sendID && field.control.value !== state.text) field.control.value = state.text || "";
      send.hidden = !choices.length; stop.hidden = !caps.canStop && !state.stopID;
      send.disabled = !choices.length || !!state.sendID || !!state.stopID; stop.disabled = !!state.stopID;
      field.wrapper.hidden = !choices.length; field.control.readOnly = !choices.length || !!state.sendID || !!state.stopID;
      var selected = choices.find(function (choice) { return choice.id === state.delivery; });
      send.textContent = state.sendID ? "发送中…" : selected ? selected.title : "发送";
      stop.textContent = state.stopID ? "停止中…" : "停止";
      feedback.textContent = state.feedback || "";
      feedback.hidden = !feedback.textContent;
      status.hidden = !status.textContent;
      detailStatus.hidden = !detailStatus.textContent;
    }
    function renderWorkspace(value) {
      var changed = S.safeArray(value.changedFiles).filter(function (path) { return typeof path === "string"; });
      var conflicts = S.safeArray(value.conflicts).filter(function (path) { return typeof path === "string"; });
      result.conflicts = conflicts;
      result.canRepair = value.workspaceStatus === "conflict"
        && (value.capabilities ? value.capabilities.canRepairWithAgent === true : value.canRepairWithAgent === true);
      repair.hidden = !result.canRepair;
      var sections = [];
      if (changed.length) sections.push("变更文件\n" + changed.join("\n"));
      if (conflicts.length) sections.push("冲突文件\n" + conflicts.join("\n"));
      var omitted = (Number(value.changedFilesOmitted) || 0) + (Number(value.conflictsOmitted) || 0);
      if (omitted > 0) sections.push("另有 " + omitted + " 项未显示。");
      changesContent.textContent = sections.join("\n\n"); changes.hidden = !sections.length;
      recovery.hidden = !options.openRecovery || !["recovery_required", "validation_required"].includes(value.workspaceStatus);
    }
    function invalidateControls() {
      result.capabilities = {}; result.canRepair = false; repair.hidden = true;
      status.textContent = state.stopID ? "正在停止…" : "待核对";
      detailStatus.textContent = status.textContent; syncControls();
    }
    var result = { id: id, item: itemButton, detail: detail, label: label, status: status,
      detailLabel: detailLabel, detailStatus: detailStatus, workspaceReason: workspaceReason, history: history, historyStatus: historyStatus,
      sessionID: null, taskID: null, runID: null, mode: "native", rawStatus: "", capabilities: {},
      childHistory: null, conflicts: [], canRepair: false, loadedOnce: false,
      syncControls: syncControls, renderWorkspace: renderWorkspace, invalidateControls: invalidateControls };
    syncControls();
    return result;
  }
  global.CodexBridgeDesktopEmbeddedDSHChildView = { create: create };
}(window));
