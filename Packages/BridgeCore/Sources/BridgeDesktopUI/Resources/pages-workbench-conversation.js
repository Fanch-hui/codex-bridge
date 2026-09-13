(function (global) {
  "use strict";
  var S = global.CodexBridgeDesktopPageSupport;
  var disclosures = new Map(), viewports = new Map(), viewportKey = null;

  function contextKey(page) {
    var task = page.selectedTask;
    return JSON.stringify([page.selectedProjectID, task && task.providerID,
      task ? task.sessionID || task.taskID : page.history && page.history.selectedThreadID]);
  }

  function captureViewport(container, page) {
    if (viewportKey !== null) {
      viewports.set(viewportKey, { top: container.scrollTop,
        following: container.scrollHeight - container.clientHeight - container.scrollTop <= 40 });
    }
    viewportKey = contextKey(page);
    var position = viewports.get(viewportKey);
    return function () {
      container.scrollTop = !position || position.following ? container.scrollHeight : position.top;
    };
  }

  function addConversationBlock(container, values, page, emit) {
    container.appendChild(S.node("h4", "subsection-title", "对话"));
    var state = page.selectedTask && page.selectedTask.conversationState;
    if (state && state.errorMessage) container.appendChild(conversationError(state.errorMessage));
    var list = S.node("div", "conversation-list");
    if (state && state.isLoading && !state.showsActivity) {
      list.appendChild(conversationLoading("正在同步对话内容…"));
    }
    if (state && state.isLoadingEarlier) list.appendChild(earlierLoading());
    if (!values.length && state && !state.isLoading && !state.showsActivity && !state.errorMessage) {
      list.appendChild(S.node("p", "muted", "暂无对话记录。"));
    }
    values.forEach(function (entry) {
      if (entry.kind === "reasoning" || entry.kind === "tool_call") {
        list.appendChild(conversationDisclosure(entry, contextKey(page)));
      } else {
        list.appendChild(conversationMessage(entry));
      }
    });
    if (state && state.showsActivity) list.appendChild(conversationActivity(state));
    container.appendChild(list);
    var actions = S.node("div", "conversation-actions");
    var canLoadEarlier = state && typeof state.canLoadEarlier === "boolean"
      ? state.canLoadEarlier
      : page.browser && page.browser.canLoadEarlierConversation;
    if (page.selectedTaskID && (canLoadEarlier || (state && state.isLoadingEarlier))) {
      var earlier = S.button(
        state && state.isLoadingEarlier ? "正在加载更早消息…" : "加载更早的消息",
        "loadEarlierConversation",
        { taskID: page.selectedTaskID },
        emit,
        "small",
        !!(state && state.isLoadingEarlier)
      );
      if (state && state.isLoadingEarlier) earlier.setAttribute("aria-busy", "true");
      actions.appendChild(earlier);
    }
    if (page.selectedTaskID) {
      actions.appendChild(S.button("刷新对话", "refreshConversation", { taskID: page.selectedTaskID }, emit, "small", false));
    }
    if (actions.childNodes.length) container.appendChild(actions);
  }

  function conversationMessage(entry) {
    var isUser = entry.role === "用户";
    var item = S.node("article", "conversation-entry entry-message " + (isUser ? "entry-user" : "entry-agent") + (entry.isFinal ? "" : " entry-streaming"));
    item.appendChild(S.markdown(entry.text, "entry-text markdown-body", entry.markdownHTML));
    return item;
  }

  function conversationDisclosure(entry, context) {
    var item = S.node("details", "conversation-entry entry-disclosure entry-" + entry.kind);
    var key = JSON.stringify([context, entry.id]);
    var expanded = disclosures.has(key) ? disclosures.get(key) : false;
    item.open = expanded;
    item.addEventListener("toggle", function () {
      if (item.open === expanded) return;
      expanded = item.open;
      disclosures.set(key, expanded);
    });
    var summary = S.node("summary", "entry-heading disclosure-summary");
    summary.appendChild(S.icon("chevron.right", "entry-disclosure-chevron"));
    summary.appendChild(statusIcon(entry));
    summary.appendChild(S.node("span", "entry-title", entry.displayTitle || entry.toolName || (entry.kind === "reasoning" ? "分析过程" : "工具调用")));
    var status = entry.displayStatus || toolStatusLabel(entry);
    if (status) summary.appendChild(S.badge(status, toolStatusTone(entry)));
    if (entry.kind === "reasoning" && !entry.isFinal) {
      summary.appendChild(S.node("span", "conversation-state-spinner entry-status-spinner", ""));
    }
    item.appendChild(summary);
    var body = S.node("div", "disclosure-body");
    if (entry.kind === "tool_call") {
      var details = entry.toolArguments || entry.text;
      if (details) body.appendChild(S.node("pre", "entry-arguments entry-details mono", details));
    } else if (entry.text) {
      body.appendChild(S.markdown(entry.text, "entry-text markdown-body", entry.markdownHTML));
    }
    item.appendChild(body);
    return item;
  }

  function statusIcon(entry) {
    var status = normalizeStatus(entry.toolStatus);
    if (entry.kind === "reasoning") {
      return S.icon(entry.symbol || "brain.head.profile", "entry-symbol entry-status-reasoning");
    }
    if (status === "failed") return S.icon("xmark.circle.fill", "entry-symbol entry-status-error");
    if (status === "cancelled") return S.icon("xmark.circle", "entry-symbol entry-status-completed");
    if (status === "declined") return S.icon("minus.circle.fill", "entry-symbol entry-status-declined");
    if (status === "completed") {
      return S.icon(entry.symbol || "wrench.and.screwdriver", "entry-symbol entry-status-completed");
    }
    return S.node("span", "conversation-state-spinner entry-status-spinner", "");
  }

  function toolStatusLabel(entry) {
    switch (normalizeStatus(entry.toolStatus)) {
    case "completed": return "";
    case "failed": return "失败";
    case "declined": return "已拒绝";
    case "cancelled": return "已取消";
    case "pending": return "等待执行";
    default: return entry.isFinal ? "" : "进行中";
    }
  }

  function toolStatusTone(entry) {
    var status = normalizeStatus(entry.toolStatus);
    if (status === "failed") return "error";
    if (status === "declined") return "warning";
    if (status === "completed" || status === "cancelled") return "neutral";
    return "running";
  }

  function normalizeStatus(value) {
    return String(value || "").toLowerCase().replace(/[-\s]/g, "_");
  }

  function conversationError(message) {
    var item = S.node("div", "conversation-state conversation-state-error");
    item.setAttribute("role", "alert");
    item.appendChild(S.icon("xmark.circle.fill", "conversation-state-icon"));
    item.appendChild(S.node("span", null, message));
    return item;
  }

  function conversationLoading(statusText) {
    var item = S.node("div", "conversation-state conversation-state-loading");
    item.setAttribute("role", "status");
    item.setAttribute("aria-live", "polite");
    item.appendChild(S.node("span", "conversation-state-spinner", ""));
    item.appendChild(S.node("span", null, statusText || "正在读取对话…"));
    return item;
  }

  function earlierLoading() {
    var item = S.node("div", "conversation-state conversation-state-earlier");
    item.setAttribute("role", "status");
    item.setAttribute("aria-live", "polite");
    item.appendChild(S.node("span", "conversation-state-spinner", ""));
    item.appendChild(S.node("span", null, "正在加载更早的消息…"));
    return item;
  }

  function conversationActivity(state) {
    var item = S.node("div", "conversation-state conversation-state-activity");
    item.setAttribute("role", "status");
    item.setAttribute("aria-live", "polite");
    item.appendChild(S.node("span", "conversation-state-spinner", ""));
    var copy = S.node("div", "conversation-state-copy");
    copy.appendChild(S.node("div", "conversation-state-title", state.statusText || "正在处理任务…"));
    if (state.detailText) copy.appendChild(S.node("div", "conversation-state-detail", state.detailText));
    item.appendChild(copy);
    return item;
  }

  global.CodexBridgeDesktopWorkbenchConversation = { render: addConversationBlock, captureViewport: captureViewport };
}(window));
