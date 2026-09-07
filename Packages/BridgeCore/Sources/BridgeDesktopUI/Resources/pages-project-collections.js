(function (global) {
  "use strict";
  var S = global.CodexBridgeDesktopPageSupport;
  function renderReadonlyCollections(container, page, emit) {
    if (page.verificationCommands && page.verificationCommands.length) addValues(container, "验证命令", page.verificationCommands, true);
    addSessionRows(container, page.sessions, emit);
    addRows(container, "Codex 外部历史会话", page.threads, "threadID", function (thread) {
      emit("openThread", { threadID: thread.threadID, projectID: page.selectedProjectID });
    });
    if (page.selectedThreadConversation && page.selectedThreadConversation.length) {
      addThreadTranscript(container, page.selectedThreadTitle, page.selectedThreadConversation);
    }
    addRows(container, "Skills", page.skills, "skillID");
  }

  function addSessionRows(container, sessions, emit) {
    var card = S.node("div", "page-card");
    card.appendChild(S.node("h3", null, "项目会话与任务"));
    var values = S.safeArray(sessions);
    if (!values.length) card.appendChild(S.node("div", "list-empty", "该项目目前没有 Agent 会话记录。"));
    values.forEach(function (session) {
      var row = S.node("div", "list-row session-row");
      var open = S.node("button", "session-open");
      open.type = "button";
      open.appendChild(S.icon("bubble.left.and.text.bubble.right.fill", "icon"));
      var copy = S.node("div", "row-main");
      copy.appendChild(S.node("div", "row-title", session.title));
      copy.appendChild(S.node("div", "row-detail", session.provider + " · " + session.turnCount + " 轮 · " + session.status));
      open.appendChild(copy);
      open.addEventListener("click", function () { emit("selectTask", { taskID: session.taskID }); });
      row.appendChild(open);
      if (session.canDelete) {
        var remove = S.button("删除", null, {}, emit, "small danger", false);
        remove.addEventListener("click", function () {
          if (global.confirm("删除会话？\n该会话的全部轮次任务、事件和对话记录都会被删除。")) {
            emit("deleteSession", { taskID: session.taskID, sessionID: session.sessionID });
          }
        });
        row.appendChild(remove);
      }
      card.appendChild(row);
    });
    container.appendChild(card);
  }

  function addThreadTranscript(container, title, entries) {
    var card = S.node("div", "page-card");
    card.appendChild(S.node("h3", null, title || "Thread 对话历史"));
    var list = S.node("div", "conversation-list");
    entries.forEach(function (entry) {
      var item = S.node("article", "conversation-entry " + (entry.role === "用户" ? "entry-user" : "entry-agent"));
      item.appendChild(S.node("div", "entry-role", entry.role));
      item.appendChild(S.markdown(entry.text, "entry-text markdown-body"));
      list.appendChild(item);
    });
    card.appendChild(list);
    container.appendChild(card);
  }

  function addValues(container, title, values, mono) {
    var card = S.node("div", "page-card");
    card.appendChild(S.node("h3", null, title));
    values.forEach(function (value) { card.appendChild(S.node("div", mono ? "page-message mono" : "page-message", value)); });
    container.appendChild(card);
  }

  function addRows(container, title, rows, idKey, onClick) {
    var card = S.node("div", "page-card");
    card.appendChild(S.node("h3", null, title));
    if (!rows || !rows.length) card.appendChild(S.node("div", "list-empty", "暂无记录。"));
    S.safeArray(rows).forEach(function (row) {
      var element = S.node(onClick ? "button" : "div", onClick ? "list-row" : "page-message");
      if (onClick) { element.type = "button"; element.addEventListener("click", function () { onClick(row); }); }
      var title = row.title || row.name || row[idKey];
      var detail = row.preview || row.description || "";
      element.appendChild(S.node("span", "row-main", title));
      if (detail) element.appendChild(S.node("span", "row-detail", detail));
      if (row.scope) element.appendChild(S.badge(row.scope, "neutral"));
      if (row.actionCount) element.appendChild(S.badge("动作 " + row.actionCount, "neutral"));
      if (row.status) element.appendChild(S.badge(row.status, "neutral"));
      card.appendChild(element);
    });
    container.appendChild(card);
  }

  global.CodexBridgeDesktopProjectCollections = { render: renderReadonlyCollections };
}(window));
