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
    var list = S.node("div", "conversation-list");
    values.forEach(function (entry) {
      if (entry.kind === "reasoning" || entry.kind === "tool_call") {
        list.appendChild(conversationDisclosure(entry, contextKey(page)));
      } else {
        list.appendChild(conversationMessage(entry));
      }
    });
    container.appendChild(list);
    var actions = S.node("div", "conversation-actions");
    if (page.selectedTaskID && page.browser && page.browser.canLoadEarlierConversation) {
      actions.appendChild(S.button("加载更早对话", "loadEarlierConversation", { taskID: page.selectedTaskID }, emit, "small", false));
    }
    if (page.selectedTaskID) {
      actions.appendChild(S.button("刷新对话", "refreshConversation", { taskID: page.selectedTaskID }, emit, "small", false));
    }
    if (actions.childNodes.length) container.appendChild(actions);
  }

  function conversationMessage(entry) {
    var isUser = entry.role === "用户";
    var item = S.node("article", "conversation-entry entry-message " + (isUser ? "entry-user" : "entry-agent"));
    var heading = S.node("div", "entry-heading");
    heading.appendChild(S.node("span", "entry-role", entry.role));
    if (!entry.isFinal) heading.appendChild(S.badge("流式", "running"));
    item.appendChild(heading);
    item.appendChild(S.markdown(entry.text, "entry-text markdown-body"));
    return item;
  }

  function conversationDisclosure(entry, context) {
    var item = S.node("details", "conversation-entry entry-disclosure entry-" + entry.kind);
    var key = JSON.stringify([context, entry.id]);
    var expanded = disclosures.has(key) ? disclosures.get(key) : !entry.isFinal;
    item.open = expanded;
    item.addEventListener("toggle", function () {
      if (item.open === expanded) return;
      expanded = item.open;
      disclosures.set(key, expanded);
    });
    var summary = S.node("summary", "entry-heading disclosure-summary");
    summary.appendChild(S.icon(entry.symbol || (entry.kind === "reasoning" ? "brain.head.profile" : "gearshape"), "entry-symbol"));
    summary.appendChild(S.node("span", "entry-title", entry.displayTitle || entry.toolName || entry.role));
    if (entry.displayStatus) {
      summary.appendChild(S.badge(entry.displayStatus, entry.toolStatus === "failed" ? "error" : "neutral"));
    }
    if (!entry.isFinal) summary.appendChild(S.badge("流式", "running"));
    item.appendChild(summary);
    var body = S.node("div", "disclosure-body");
    if (entry.text) body.appendChild(S.markdown(entry.text, "entry-text markdown-body"));
    if (entry.toolArguments) body.appendChild(S.node("pre", "entry-arguments mono", entry.toolArguments));
    item.appendChild(body);
    return item;
  }

  global.CodexBridgeDesktopWorkbenchConversation = { render: addConversationBlock, captureViewport: captureViewport };
}(window));
