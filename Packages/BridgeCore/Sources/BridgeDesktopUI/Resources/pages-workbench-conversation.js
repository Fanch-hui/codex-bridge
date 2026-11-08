(function (global) {
  "use strict";
  var S = global.CodexBridgeDesktopPageSupport;
  var disclosures = new Map(), viewports = new Map(), viewportKey = null, activeContextKey = null;
  var searchReveal = null;

  function reveal(taskID, messageKey) {
    searchReveal = taskID && messageKey
      ? { taskID: String(taskID), key: String(messageKey), scrolled: false }
      : null;
  }

  function hasSearchReveal(taskID) {
    return !!(searchReveal && searchReveal.taskID === taskID);
  }

  function showSearchMatch(container, page, options) {
    if (!hasSearchReveal(page.selectedTaskID)) return;
    var match = Array.from(container.querySelectorAll("[data-message-key]")).find(function (item) {
      return item.dataset.messageKey === searchReveal.key;
    });
    if (!match) return;
    match.classList.add("is-search-match");
    if (searchReveal.scrolled) return;
    searchReveal.scrolled = true;
    var anchor = searchReveal;
    var scroll = function () {
      if (searchReveal !== anchor || !match.isConnected) return;
      var owner = options && options.owner;
      if (owner && owner.__conversationFollow) owner.__conversationFollow.following = false;
      match.scrollIntoView({ block: "center" });
    };
    if (global.requestAnimationFrame) global.requestAnimationFrame(scroll);
    else scroll();
  }

  function returnToLatest(taskID, emit) {
    searchReveal = null;
    emit("refreshConversation", { taskID: taskID });
  }

  function contextKey(page) {
    var task = page.selectedTask;
    var projectID = task && task.projectID;
    if (!projectID && task && Array.isArray(page.tasks)) {
      var matched = page.tasks.find(function (item) { return item.taskID === task.taskID; });
      if (matched) projectID = matched.projectID;
    }
    return JSON.stringify([projectID || page.selectedProjectID, task && task.providerID,
      task ? task.sessionID || task.taskID : page.history && page.history.selectedThreadID]);
  }

  var recentContextKeys = [];
  function pruneContextState(page) {
    var key = contextKey(page);
    if (activeContextKey === key) return;
    activeContextKey = key;
    // Contexts accumulate disclosure and viewport state forever otherwise; keep the few
    // conversations on screen (the split view shows up to four) so long sessions stay bounded.
    recentContextKeys = [key].concat(recentContextKeys.filter(function (k) { return k !== key; })).slice(0, 6);
    [disclosures, viewports].forEach(function (map) {
      Array.from(map.keys()).forEach(function (k) { if (recentContextKeys.indexOf(k) < 0) map.delete(k); });
    });
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
      followContentSize(container, !position || position.following);
    };
  }

  function followContentSize(container, following) {
    if (!container.addEventListener) return;
    var tracker = container.__conversationFollow;
    if (!tracker) {
      tracker = container.__conversationFollow = { following: following, frame: null };
      var align = function () {
        tracker.frame = null;
        if (tracker.following) container.scrollTop = container.scrollHeight;
      };
      tracker.schedule = function () {
        if (tracker.frame !== null) return;
        if (global.requestAnimationFrame) tracker.frame = global.requestAnimationFrame(align);
        else align();
      };
      container.addEventListener("scroll", function () {
        tracker.following = container.scrollHeight - container.clientHeight - container.scrollTop <= 40;
      }, { passive: true });
      container.addEventListener("wheel", function (event) {
        if (event.deltaY < 0) tracker.following = false;
      }, { passive: true });
      if (global.ResizeObserver) tracker.observer = new global.ResizeObserver(tracker.schedule);
    }
    tracker.following = following;
    if (tracker.observer) {
      tracker.observer.disconnect();
      Array.from(container.children).forEach(function (child) { tracker.observer.observe(child); });
    }
    tracker.schedule();
  }

  function addConversationBlock(container, values, page, emit, options) {
    pruneContextState(page);
    var submissions = global.CodexBridgeDesktopWorkbenchSubmissions;
    if (submissions) values = submissions.entries(values, page);
    var process = global.CodexBridgeDesktopWorkbenchProcess;
    if (process) values = process.entries(values, page);
    var incremental = global.CodexBridgeDesktopWorkbenchConversationIncremental;
    if (incremental) {
      incremental.render(container, values, page, emit, options);
      showSearchMatch(container, page, options);
      return;
    }
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
      if (entry.kind === "process") {
        list.appendChild(process.create(entry, contextKey(page)));
      } else if (entry.kind === "reasoning" || entry.kind === "tool_call") {
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
    if (hasSearchReveal(page.selectedTaskID)) {
      var latest = S.button("返回最新消息", null, {}, null, "small", false);
      latest.addEventListener("click", function () {
        latest.disabled = true;
        returnToLatest(page.selectedTaskID, emit);
      });
      actions.appendChild(latest);
    }
    if (actions.childNodes.length) container.appendChild(actions);
    showSearchMatch(container, page, options);
  }

  function conversationMessage(entry) {
    var upstream = global.CodexBridgeDesktopDSHConversationView;
    if (upstream) return upstream.create(entry);
    var item = S.node("article", "conversation-entry entry-message");
    updateMessage(item, entry);
    return item;
  }

  function updateMessage(item, entry) {
    if (item.__dshHost) return global.CodexBridgeDesktopDSHConversationView.update(item, entry);
    var isUser = entry.role === "用户";
    item.className = "conversation-entry entry-message " + (isUser ? "entry-user" : "entry-agent") + (entry.isFinal ? "" : " entry-streaming");
    item.dataset.messageKey = String(entry.id);
    if (!item.__text) {
      item.__text = S.markdown(entry.text, "entry-text markdown-body", entry.markdownHTML);
      item.appendChild(item.__text);
    } else {
      updateTextNode(item.__text, entry.text, entry.markdownHTML);
    }
    if (entry.deliveryState && !item.__delivery) {
      item.__delivery = S.node("div", "message-delivery");
      item.__delivery.setAttribute("role", "status");
      item.__delivery.setAttribute("aria-live", "polite");
      item.appendChild(item.__delivery);
    }
    if (item.__delivery) {
      item.__delivery.hidden = !entry.deliveryState;
      item.__delivery.textContent = entry.deliveryMessage || "";
      item.__delivery.className = "message-delivery" + (entry.deliveryState === "failed" ? " error-text" : "");
    }
  }

  function updateTextNode(node, value, html) {
    if (typeof html === "string") {
      if (node.innerHTML !== html) node.innerHTML = html;
    } else {
      var text = value || "";
      if (node.textContent !== text) node.textContent = text;
    }
  }

  function conversationDisclosure(entry, context) {
    var upstream = global.CodexBridgeDesktopDSHConversationView;
    if (upstream) return upstream.create(entry, context);
    var item = S.node("details", "conversation-entry entry-disclosure");
    item.__disclosureKey = null;
    item.addEventListener("toggle", function () {
      if (item.__disclosureKey !== null) disclosures.set(item.__disclosureKey, !!item.open);
    });
    updateDisclosure(item, entry, context);
    return item;
  }

  function updateDisclosure(item, entry, context) {
    if (item.__dshHost) return global.CodexBridgeDesktopDSHConversationView.update(item, entry, context);
    var key = JSON.stringify([context, entry.id]);
    var isNewContext = item.__disclosureKey !== key;
    if (disclosures.has(key)) item.open = disclosures.get(key);
    else if (isNewContext) item.open = false;
    item.__disclosureKey = key;
    var toolName = String(entry.toolName || "").toLowerCase();
    var subagent = /(^|[_\s-])(subagent|delegate|fork|agent|task)([_\s-]|$)/.test(toolName);
    item.className = "conversation-entry entry-disclosure entry-" + entry.kind + (subagent ? " entry-subagent" : "");
    var summary = item.__summary || (item.__summary = S.node("summary", "entry-heading disclosure-summary"));
    S.clear(summary);
    summary.appendChild(S.icon("chevron.right", "entry-disclosure-chevron"));
    summary.appendChild(statusIcon(entry));
    summary.appendChild(S.node("span", "entry-title", entry.displayTitle || entry.toolName || (entry.kind === "reasoning" ? "分析过程" : "工具调用")));
    var status = entry.displayStatus || toolStatusLabel(entry);
    if (status) summary.appendChild(S.badge(status, toolStatusTone(entry)));
    if (entry.kind === "reasoning" && !entry.isFinal) {
      summary.appendChild(S.node("span", "conversation-state-spinner entry-status-spinner", ""));
    }
    if (summary.parentNode !== item) item.appendChild(summary);
    var body = item.__body || (item.__body = S.node("div", "disclosure-body"));
    if (body.parentNode !== item) item.appendChild(body);
    if (entry.kind === "tool_call") {
      if (item.__reasoningText) item.__reasoningText.hidden = true;
      updateToolBody(item, entry);
    } else if (entry.text) {
      item.__reasoningText = item.__reasoningText || S.markdown("", "entry-text markdown-body");
      updateTextNode(item.__reasoningText, entry.text, entry.markdownHTML);
      if (item.__reasoningText.parentNode !== body) body.appendChild(item.__reasoningText);
      hideToolBlocks(item);
    } else if (item.__reasoningText) {
      item.__reasoningText.hidden = true;
      hideToolBlocks(item);
    }
    updateChildRuns(item, entry);
    if (item.__reasoningText && entry.kind === "reasoning") item.__reasoningText.hidden = !entry.text;
  }

  function toolValue(value) {
    if (value === null || value === undefined) return "";
    var text = String(value).replace(/\r\n?/g, "\n");
    if (!text.trim()) return "";
    try { return JSON.stringify(JSON.parse(text), null, 2); } catch (_) { return text; }
  }

  function toolBlock(item, key, title, className, value) {
    var block = item[key];
    if (!block) {
      block = item[key] = S.node("div", "entry-tool-block");
      block.__label = S.node("div", "entry-detail-label", title);
      block.__value = S.node("pre", className + " entry-details mono");
      block.appendChild(block.__label); block.appendChild(block.__value);
      item.__body.appendChild(block);
    }
    var text = toolValue(value);
    block.hidden = !text;
    if (text && block.__value.textContent !== text) block.__value.textContent = text;
  }

  function hideToolBlocks(item) {
    if (item.__toolName) item.__toolName.hidden = true;
    if (item.__toolInput) item.__toolInput.hidden = true;
    if (item.__toolOutput) item.__toolOutput.hidden = true;
    if (item.__toolJobs) item.__toolJobs.hidden = true;
  }

  function updateToolBody(item, entry) {
    var body = item.__body;
    if (entry.toolName) {
      if (!item.__toolName) {
        item.__toolName = S.node("div", "entry-tool-name mono");
        if (body.firstChild) body.insertBefore(item.__toolName, body.firstChild);
        else body.appendChild(item.__toolName);
      }
      item.__toolName.hidden = false;
      item.__toolName.textContent = "工具：" + entry.toolName;
    } else if (item.__toolName) {
      item.__toolName.hidden = true;
    }
    toolBlock(item, "__toolInput", "输入", "entry-arguments", entry.toolArguments);
    toolBlock(item, "__toolOutput", "输出", "entry-output", entry.text);
    toolBlock(item, "__toolJobs", "后台任务", "entry-output", entry.jobDetails);
  }

  function childStatusTone(status) {
    var value = String(status || "").toLowerCase().replace(/[-\s]/g, "_");
    if (["failed", "error", "errored"].includes(value)) return "error";
    if (["declined", "denied", "cancelled", "canceled"].includes(value)) return "warning";
    if (["completed", "success", "succeeded"].includes(value)) return "success";
    if (["pending", "queued", "running", "in_progress", "active"].includes(value)) return "running";
    return "neutral";
  }

  function updateChildRuns(item, entry) {
    var runs = Array.isArray(entry.childRuns) ? entry.childRuns : [];
    var section = item.__childRuns;
    if (!section) {
      section = item.__childRuns = S.node("section", "entry-child-runs");
      section.appendChild(S.node("div", "entry-detail-label", "子代理"));
      section.__list = S.node("div", "entry-child-run-list");
      section.appendChild(section.__list);
      item.__body.appendChild(section);
      section.__nodes = new Map();
    }
    section.hidden = runs.length === 0;
    var active = new Set();
    runs.forEach(function (run) {
      if (!run || !run.id) return;
      active.add(run.id);
      var row = section.__nodes.get(run.id);
      if (!row) {
        row = S.node("div", "entry-child-run");
        row.__name = S.node("span", "entry-child-run-name");
        row.__status = S.node("span", "entry-child-run-status");
        row.__summary = S.node("div", "entry-child-run-summary");
        row.__workspaces = S.node("div", "entry-child-run-workspaces mono");
        row.appendChild(row.__name);
        row.appendChild(row.__status);
        row.appendChild(row.__summary);
        row.appendChild(row.__workspaces);
        section.__nodes.set(run.id, row);
      }
      row.__name.textContent = run.name || run.id;
      row.__status.textContent = run.status || "";
      row.__status.hidden = !run.status;
      row.__status.className = "entry-child-run-status status-badge " + childStatusTone(run.status);
      row.__summary.textContent = run.summary || "";
      row.__summary.hidden = !run.summary;
      var workspaceURLs = Array.isArray(run.workspaceURLs) ? run.workspaceURLs.filter(Boolean) : [];
      row.__workspaces.textContent = workspaceURLs.join("\n");
      row.__workspaces.hidden = workspaceURLs.length === 0;
      if (row.parentNode !== section.__list) section.__list.appendChild(row);
    });
    section.__nodes.forEach(function (row, id) {
      if (!active.has(id)) { row.remove(); section.__nodes.delete(id); }
    });
  }

  function statusIcon(entry) {
    var status = normalizeStatus(entry.toolStatus);
    if (entry.kind === "reasoning") {
      return S.icon(entry.symbol || "brain.head.profile", "entry-symbol entry-status-reasoning");
    }
    if (status === "not_git") return S.icon("folder", "entry-symbol entry-status-completed");
    if (status === "failed") return S.icon("xmark.circle.fill", "entry-symbol entry-status-error");
    if (status === "cancelled") return S.icon("xmark.circle", "entry-symbol entry-status-completed");
    if (status === "declined") return S.icon("minus.circle.fill", "entry-symbol entry-status-declined");
    if (status === "completed") {
      return S.icon(entry.symbol || "wrench.and.screwdriver", "entry-symbol entry-status-completed");
    }
    if (status === "in_progress" || status === "pending") {
      return S.node("span", "conversation-state-spinner entry-status-spinner", "");
    }
    return S.icon(entry.symbol || "wrench.and.screwdriver", "entry-symbol entry-status-completed");
  }

  function toolStatusLabel(entry) {
    switch (normalizeStatus(entry.toolStatus)) {
    case "completed": return "";
    case "not_git": return "非 Git 项目";
    case "failed": return "失败";
    case "declined": return "已拒绝";
    case "cancelled": return "已取消";
    case "pending": return "等待执行";
    case "in_progress": return "进行中";
    default: return entry.toolStatus || (entry.isFinal ? "" : "状态未知");
  }
  }

  function toolStatusTone(entry) {
    var status = normalizeStatus(entry.toolStatus);
    if (status === "not_git") return "neutral";
    if (status === "failed") return "error";
    if (status === "declined") return "warning";
    if (status === "completed" || status === "cancelled") return "neutral";
    return status === "in_progress" || status === "pending" ? "running" : "neutral";
  }

  function normalizeStatus(value) {
    var status = String(value || "").toLowerCase().replace(/[-\s]/g, "_");
    if (status === "inprogress" || status === "running" || status === "active") return "in_progress";
    if (status === "success" || status === "succeeded") return "completed";
    if (status === "canceled" || status === "interrupted") return "cancelled";
    if (status === "denied" || status === "rejected") return "declined";
    if (status === "queued" || status === "waiting") return "pending";
    return status;
  }

  function conversationError(message) {
    var item = S.node("div", "conversation-state conversation-state-error");
    item.setAttribute("role", "alert");
    item.appendChild(S.icon("xmark.circle.fill", "conversation-state-icon"));
    item.__message = S.node("span", null, message);
    item.appendChild(item.__message);
    return item;
  }

  function conversationLoading(statusText) {
    var item = S.node("div", "conversation-state conversation-state-loading");
    item.setAttribute("role", "status");
    item.setAttribute("aria-live", "polite");
    item.appendChild(S.node("span", "conversation-state-spinner", ""));
    item.__statusText = S.node("span", null, statusText || "正在读取对话…");
    item.appendChild(item.__statusText);
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
    item.__activityCopy = S.node("div", "conversation-state-copy");
    item.appendChild(item.__activityCopy);
    updateActivityNode(item, state);
    return item;
  }

  function updateActivityNode(item, state) {
    // Background work reads as one quiet line, like a native agent's working indicator.
    var text = String(state.detailText || state.statusText || "正在处理").replace(/[…\.]+$/, "");
    if (item.__activityText === text) return item;
    item.__activityText = text;
    S.clear(item.__activityCopy);
    item.__activityCopy.appendChild(S.node("span", "conversation-state-title workbench-working-indicator", text));
    return item;
  }

  global.CodexBridgeDesktopWorkbenchConversation = {
    render: addConversationBlock,
    reveal: reveal,
    hasSearchReveal: hasSearchReveal,
    returnToLatest: returnToLatest,
    captureViewport: captureViewport,
    contextKey: contextKey,
    createMessage: conversationMessage,
    updateMessage: updateMessage,
    createDisclosure: conversationDisclosure,
    updateDisclosure: updateDisclosure,
    createError: conversationError,
    createLoading: conversationLoading,
    createEarlierLoading: earlierLoading,
    createActivity: conversationActivity,
    updateActivity: updateActivityNode
  };
}(window));
