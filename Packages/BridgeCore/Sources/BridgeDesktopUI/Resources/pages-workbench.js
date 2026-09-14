(function (global) {
  "use strict";

  var S = global.CodexBridgeDesktopPageSupport;
  var N = global.CodexBridgeDesktopNativePermissions;

  function renderApprovals(page, emit) {
    var container = document.getElementById("workbench-inspector-approvals");
    renderStable(container, JSON.stringify(page.approvals || []), function () {
    S.clear(container);
    if (!page.approvals || page.approvals.length === 0) return;
    var section = S.node("div", "approvals-tray");
    page.approvals.forEach(function (appr) {
      var card = S.node("article", "approval-card");
      card.appendChild(S.node("h4", null, appr.title || appr.kind));
      var body = S.node("div", "approval-body");
      card.appendChild(body);
      body.appendChild(S.node("p", null, appr.summary));
      if (appr.displayCommand) body.appendChild(S.node("pre", "mono", appr.displayCommand));
      if (appr.reason) body.appendChild(S.node("p", null, appr.reason));
      if (appr.relativePaths && appr.relativePaths.length) addListBlock(body, "涉及路径", appr.relativePaths);
      var actions = S.node("div", "approval-actions");
      var decs = appr.decisionOptions && appr.decisionOptions.length ? appr.decisionOptions : ["allow", "deny"];
      if (appr.canDeny && !decs.some(function (d) { return d.toLowerCase() === "deny"; })) {
        decs = decs.concat(["deny"]);
      }
      decs = decs.filter(function (decision, index) { return decs.indexOf(decision) === index; });
      decs.forEach(function (dec) {
        var normalized = dec.toLowerCase(), isDeny = normalized === "deny";
        var allowed = isDeny ? appr.canDeny : appr.canAllow;
        var cmd = appr.isDirect ? "resolveDirectApproval" : "resolveApproval";
        actions.appendChild(S.button(decisionLabel(appr, dec), cmd,
          { approvalID: appr.approvalID, taskID: appr.taskID, decision: dec }, emit,
          isDeny ? "small danger" : "small primary", appr.resolving || !allowed));
      });
      var oneTimeButton = N && N.oneTimeApprovalButton(appr, emit);
      if (oneTimeButton) actions.appendChild(oneTimeButton);
      card.appendChild(actions); section.appendChild(card);
    });
    container.appendChild(section);
    });
  }

  function renderStable(container, signature, render) {
    if (!container.__renderState) {
      var state = container.__renderState = { pressed: false, signature: null, pending: null };
      container.addEventListener("pointerdown", function () { state.pressed = true; });
      container.addEventListener("keydown", function (event) {
        if ((event.key === "Enter" || event.key === " ") && event.target.closest("button")) {
          state.pressed = true;
        }
      });
      function release() {
        setTimeout(function () {
          state.pressed = false;
          var pending = state.pending;
          state.pending = null;
          if (pending) pending();
        }, 0);
      }
      global.addEventListener("pointerup", release);
      global.addEventListener("pointercancel", release);
      global.addEventListener("keyup", release);
      global.addEventListener("blur", release);
    }
    var state = container.__renderState;
    if (state.pressed) {
      state.pending = function () { renderStable(container, signature, render); };
      return;
    }
    if (state.signature === signature) return;
    render();
    state.signature = signature;
  }

  function renderContent(page, emit) {
    var content = document.getElementById("workbench-inspector-content");
    renderStable(content, JSON.stringify(page), function () {
      var restore = global.CodexBridgeDesktopWorkbenchConversation.captureViewport(content, page);
      try { renderContentBody(content, page, emit); } finally { restore(); }
    });
  }

  function renderContentBody(content, page, emit) {
    S.clear(content);
    if (!page.selectedTask) {
      var empty = S.node("div", "workbench-empty-state");
      empty.appendChild(S.icon("sparkles", "empty-sparkle-icon"));
      empty.appendChild(S.node("h3", "empty-title", "等待 ChatGPT 指令"));
      empty.appendChild(S.node("p", "empty-desc", "在左侧 ChatGPT 网页版发起提问并调用 MCP 工具，本面板将实时呈现任务流与所选 Provider 的执行结果。"));
      content.appendChild(empty);
      return;
    }
    var detail = page.selectedTask, row = S.safeArray(page.tasks).find(function (t) {
      return t.taskID === detail.taskID || (
        detail.sessionID &&
        t.sessionID === detail.sessionID &&
        t.providerID === detail.providerID &&
        t.projectID === page.selectedProjectID
      );
    }) || {};
    if (detail.currentStep) {
      var stepCard = S.node("div", "page-card current-step-card");
      stepCard.appendChild(S.node("div", "step-caption", "当前正在执行"));
      stepCard.appendChild(S.node("div", "step-text", detail.currentStep));
      content.appendChild(stepCard);
    }
    var remediationCard = N && N.remediationCard(detail, emit);
    if (remediationCard) content.appendChild(remediationCard);
    var card = S.node("div", "page-card task-detail-card");
    card.appendChild(S.node("h3", "detail-title", detail.title));
    card.appendChild(S.node("p", "detail-subtitle", detail.projectName + " · " + detail.provider));
    var grid = S.node("dl", "detail-grid");
    addDetail(grid, "状态", detail.status); addDetail(grid, "更新时间", detail.updatedAt);
    addDetail(grid, "模型", detail.model || "未记录"); addDetail(grid, "权限", detail.permissionMode || "未记录");
    if (detail.failureCode) addDetail(grid, "失败代码", detail.failureCode);
    card.appendChild(grid);

    var actions = S.node("div", "form-actions");
    if (detail.canInterrupt) actions.appendChild(S.button("中断", "interruptTask", { taskID: detail.taskID }, emit, "small danger", false));
    if (detail.canStop) actions.appendChild(S.button("停止", "stopTask", { taskID: detail.taskID }, emit, "small danger", false));
    if (row.canDelete) {
      var rm = S.button("删除会话", null, {}, emit, "small danger", false);
      rm.addEventListener("click", function () {
        if (global.confirm("删除会话？\n这会删除 Codex Bridge 保存的全部轮次任务、事件和对话记录，无法撤销。")) emit("deleteSession", { taskID: detail.taskID, sessionID: detail.sessionID });
      });
      actions.appendChild(rm);
    }
    actions.appendChild(S.button("刷新任务", "refreshTasks", {}, emit, "small", false));
    card.appendChild(actions);

    if (detail.resultSummary) addTextBlock(card, "结果摘要", detail.resultSummary);
    if (detail.changedFiles && detail.changedFiles.length) addListBlock(card, "变更文件", detail.changedFiles);
    if (detail.activity && detail.activity.length) addActivityBlock(card, detail.activity);
    if ((detail.conversation && detail.conversation.length) || detail.conversationState) {
      global.CodexBridgeDesktopWorkbenchConversation.render(card, detail.conversation || [], page, emit);
    }
    content.appendChild(card);
  }

  function decisionLabel(approval, decision) {
    var labels = approval.decisionLabels || {};
    if (labels[decision]) return labels[decision];
    switch (decision.toLowerCase()) {
    case "allow": return "仅本次允许";
    case "allow_for_session": return "本次会话允许";
    case "allow_similar_commands": return "允许此类命令";
    case "deny": return "拒绝";
    default: return decision;
    }
  }

  function addDetail(c, k, v) { var it = S.node("div", "detail-item"); it.appendChild(S.node("dt", null, k)); it.appendChild(S.node("dd", null, v)); c.appendChild(it); }
  function addTextBlock(c, title, text) { c.appendChild(S.node("h4", "subsection-title", title)); c.appendChild(S.node("p", "muted", text)); }
  function addListBlock(c, title, values) {
    c.appendChild(S.node("h4", "subsection-title", title));
    var list = S.node("div", "activity-list");
    values.forEach(function (v) { list.appendChild(S.node("div", "path-row mono", v)); });
    c.appendChild(list);
  }

  function addActivityBlock(container, values) {
    container.appendChild(S.node("h4", "subsection-title", "实时活动"));
    var list = S.node("div", "activity-list");
    values.forEach(function (a) {
      var row = S.node("div", "activity-row");
      row.appendChild(S.node("span", "muted mono", a.occurredAt)); row.appendChild(S.node("span", null, a.summary)); list.appendChild(row);
    });
    container.appendChild(list);
  }

  function render(page, emit) {
    if (!page) {
      global.CodexBridgeDesktopWorkbenchHeader.reset();
      global.CodexBridgeDesktopWorkbenchControls.render(null, emit);
      document.getElementById("chat-browser-slot").classList.add("browser-hidden");
      document.getElementById("browser-slot-note").textContent = "等待本机 Service 提供浏览器状态";
      return;
    }
    global.CodexBridgeDesktopWorkbenchHeader.render(page, emit);
    renderApprovals(page, emit);
    renderContent(page, emit);
    global.CodexBridgeDesktopWorkbenchControls.render(page, emit);
  }

  global.CodexBridgeDesktopWorkbenchPage = { render: render };
}(window));
