(function (global) {
  "use strict";
  var S = global.CodexBridgeDesktopPageSupport;
  var expanded = new Map();

  function sections(card) {
    var header = card.__detailHeader;
    if (!header) header = card.__detailHeader = S.node("header", "task-detail-header");
    var conversation = card.__conversationContainer;
    if (!conversation) conversation = card.__conversationContainer = S.node("section", "task-conversation-container");
    if (header.parentNode !== card) card.appendChild(header);
    if (conversation.parentNode !== card) card.appendChild(conversation);
    if (card.firstChild !== header) card.insertBefore(header, card.firstChild);
    if (card.lastChild !== conversation) card.appendChild(conversation);
    if (!header.__presentation) {
      var summary = S.node("div", "task-detail-summary");
      var title = S.node("h3", "detail-title");
      var step = S.node("div", "current-step-card");
      step.appendChild(S.node("span", "step-caption", "当前操作"));
      var stepText = S.node("span", "step-text"); step.appendChild(stepText);
      summary.appendChild(title); summary.appendChild(step);
      var actions = S.node("div", "form-actions");
      var failure = S.node("div", "task-failure-summary");
      var metadata = S.node("details", "task-metadata");
      metadata.appendChild(S.node("summary", "disclosure-summary", "会话详情"));
      var grid = S.node("dl", "detail-grid"); metadata.appendChild(grid);
      var files = S.node("div", "task-detail-files"); metadata.appendChild(files);
      var copy = S.button("复制结果", null, {}, null, "small");
      var copyStatus = S.node("span", "hint"); copyStatus.setAttribute("role", "status");
      copy.addEventListener("click", function () {
        var text = copy.__text;
        copyResult(text).then(function () {
          if (copy.__text === text) copyStatus.textContent = "已复制";
        }, function () {
          if (copy.__text === text) copyStatus.textContent = "复制失败，请选择结果文字复制。";
        });
      });
      metadata.appendChild(copy); metadata.appendChild(copyStatus);
      metadata.addEventListener("toggle", function () { expanded.set(metadata.__taskKey, !!metadata.open); });
      [summary, actions, failure, metadata].forEach(function (node) { header.appendChild(node); });
      header.__presentation = {
        title: title, step: step, stepText: stepText, actions: actions, failure: failure,
        metadata: metadata, grid: grid, files: files, conversation: conversation, copy: copy, copyStatus: copyStatus
      };
    }
    return header.__presentation;
  }

  function update(view, detail) {
    var key = JSON.stringify([detail.providerID, detail.sessionID || detail.taskID]);
    if (view.metadata.__taskKey !== key) {
      view.metadata.__taskKey = key;
      view.metadata.open = expanded.get(key) === true;
    }
    view.title.textContent = detail.title;
    view.step.hidden = !detail.currentStep || detail.isTerminal === true;
    view.stepText.textContent = detail.currentStep || "";
    S.clear(view.failure);
    view.failure.hidden = !detail.failureReason && !detail.failureNextAction;
    if (detail.failureReason) view.failure.appendChild(S.node("p", "error-text", detail.failureReason));
    if (detail.failureNextAction) view.failure.appendChild(S.node("p", null, detail.failureNextAction));
    S.clear(view.grid);
    addDetail(view.grid, "项目", detail.projectName);
    addDetail(view.grid, "Agent", detail.provider);
    addDetail(view.grid, "来源", detail.source);
    addDetail(view.grid, "更新时间", detail.updatedAt);
    addDetail(view.grid, "模型", detail.model || "未记录");
    addDetail(view.grid, "权限", detail.permissionMode || "未记录");
    if (detail.currentStep && detail.isTerminal) addDetail(view.grid, "最后执行步骤", detail.currentStep);
    addUsage(view.grid, detail.usage);
    if (detail.failureCode) addDetail(view.grid, "失败代码", detail.failureCode);
    if (detail.failureDiagnostic) addDetail(view.grid, "诊断详情", detail.failureDiagnostic);
    var copyText = detail.providerID === "deepseek-harness" ? detail.resultSummary || "" : "";
    if (view.copy.__text !== copyText) view.copyStatus.textContent = "";
    view.copy.__text = copyText; view.copy.hidden = !copyText; view.copyStatus.hidden = !copyText;
    S.clear(view.files);
    var files = S.safeArray(detail.changedFiles);
    view.files.hidden = !files.length;
    if (files.length) {
      view.files.appendChild(S.node("h4", "subsection-title", "变更文件"));
      files.forEach(function (file) { view.files.appendChild(S.node("div", "path-row mono", file)); });
    }
  }

  async function copyResult(text) {
    if (global.navigator && global.navigator.clipboard && global.navigator.clipboard.writeText) {
      try { await global.navigator.clipboard.writeText(text); return; } catch (_) {}
    }
    var active = document.activeElement;
    var selection = active && typeof active.selectionStart === "number"
      ? [active.selectionStart, active.selectionEnd, active.selectionDirection] : null;
    var field = S.node("textarea"); field.value = text;
    field.style.position = "fixed"; field.style.opacity = "0";
    field.setAttribute("aria-hidden", "true"); document.body.appendChild(field);
    try {
      field.focus(); field.select();
      if (!document.execCommand("copy")) throw new Error("copy_failed");
    } finally {
      field.remove();
      if (active && active.focus) {
        active.focus({ preventScroll: true });
        if (selection) active.setSelectionRange(selection[0], selection[1], selection[2]);
      }
    }
  }

  function addUsage(grid, usage) {
    if (!usage) return;
    if (usage.contextTokens != null) addDetail(grid, "上下文 Token", String(usage.contextTokens)
      + (usage.contextWindow != null ? " / " + usage.contextWindow : ""));
    else if (usage.contextUsedPercentage != null) addDetail(grid, "上下文占用", String(usage.contextUsedPercentage) + "%");
    [["inputTokens", "累计输入 Token"], ["outputTokens", "累计输出 Token"],
      ["cacheReadTokens", "缓存读取 Token"], ["cacheWriteTokens", "缓存写入 Token"],
      ["totalTokens", "累计 Token"]].forEach(function (value) {
      if (usage[value[0]] != null) addDetail(grid, value[1], String(usage[value[0]]));
    });
    if (usage.costAmount != null) addDetail(grid, usage.currency ? "费用" : "原生费用值",
      String(usage.costAmount) + (usage.currency ? " " + usage.currency : "（单位未提供）"));
  }

  function addDetail(container, title, value) {
    if (value == null || value === "") return;
    var item = S.node("div", "detail-item");
    item.appendChild(S.node("dt", null, title)); item.appendChild(S.node("dd", null, value));
    container.appendChild(item);
  }

  global.CodexBridgeDesktopWorkbenchDetails = { sections: sections, update: update };
}(window));
