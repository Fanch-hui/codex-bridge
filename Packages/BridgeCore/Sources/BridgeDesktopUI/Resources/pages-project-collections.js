(function (global) {
  "use strict";
  var S = global.CodexBridgeDesktopPageSupport;
  var disclosureState = new Map();

  function renderReadonlyCollections(container, page, emit) {
    if (page.verificationCommands && page.verificationCommands.length) addValues(container, "验证命令", page.verificationCommands, true);
    addSessionRows(container, page.sessions, page.selectedProjectID, emit);
    addThreadRows(container, page.threads, page.selectedProjectID, emit);
    if (page.selectedThreadConversation && page.selectedThreadConversation.length) {
      addThreadTranscript(container, page.selectedThreadTitle, page.selectedThreadConversation);
    }
    addSkillRows(container, page.skills, page.selectedProjectID);
  }

  function addSessionRows(container, sessions, projectID, emit) {
    var values = S.safeArray(sessions);
    var card = collectionCard(
      projectID,
      "sessions",
      "Agent 会话",
      values.length,
      values.length ? "按 Agent 分组查看项目会话与任务。" : "该项目目前没有 Agent 会话记录。"
    );
    if (!values.length) {
      card.body.appendChild(S.node("div", "list-empty", "暂无会话。"));
    } else {
      groupSessions(values).forEach(function (group) {
        var groupDetails = disclosure(
          projectID,
          "session:" + group.key,
          "project-agent-session-group"
        );
        var summary = S.node("summary", "project-agent-session-summary");
        summary.appendChild(S.icon("cpu.fill", "project-agent-icon"));
        summary.appendChild(S.node("span", "project-agent-name", group.label));
        summary.appendChild(S.badge(String(group.sessions.length), "neutral"));
        groupDetails.appendChild(summary);
        var list = S.node("div", "project-session-list");
        group.sessions.forEach(function (session) { list.appendChild(sessionRow(session, emit)); });
        groupDetails.appendChild(list);
        card.body.appendChild(groupDetails);
      });
    }
    container.appendChild(card.root);
  }

  function addThreadTranscript(container, title, entries) {
    var card = S.node("section", "page-card project-thread-transcript");
    card.appendChild(S.node("h3", null, title || "Codex 历史会话"));
    card.appendChild(S.node("p", "muted project-collection-description", "这是 Codex 的项目历史记录，尚未关联到当前 Bridge 任务。"));
    var list = S.node("div", "conversation-list");
    entries.forEach(function (entry) {
      var item = S.node("article", "conversation-entry " + (entry.role === "用户" ? "entry-user" : "entry-agent"));
      item.appendChild(S.node("div", "entry-role", entry.role));
      item.appendChild(S.markdown(entry.text, "entry-text markdown-body", entry.markdownHTML));
      list.appendChild(item);
    });
    card.appendChild(list);
    container.appendChild(card);
  }

  function addThreadRows(container, threads, projectID, emit) {
    var values = S.safeArray(threads);
    var card = collectionCard(
      projectID,
      "threads",
      "Codex 历史会话（未关联 Bridge 任务）",
      values.length,
      "这里显示 Codex 中属于当前项目、但没有对应 Bridge 任务的历史记录。"
    );
    var list = S.node("div", "project-thread-list");
    if (!values.length) {
      list.appendChild(S.node("div", "list-empty", "暂无 Codex 历史会话。"));
    } else {
      values.forEach(function (thread) {
        var row = S.node("button", "list-row project-thread-row");
        row.type = "button";
        var copy = S.node("div", "row-main");
        copy.appendChild(S.node("div", "row-title", thread.title || thread.preview || thread.threadID));
        copy.appendChild(S.node("div", "row-detail", thread.preview || "Codex 项目历史记录"));
        row.appendChild(S.icon("bubble.left.and.text.bubble.right.fill", "icon"));
        row.appendChild(copy);
        row.appendChild(S.badge(thread.status || "未知", "neutral"));
        row.addEventListener("click", function () {
          emit("openThread", { threadID: thread.threadID, projectID: projectID });
        });
        list.appendChild(row);
      });
    }
    card.body.appendChild(list);
    container.appendChild(card.root);
  }

  function addSkillRows(container, skills, projectID) {
    var values = S.safeArray(skills);
    var card = collectionCard(
      projectID,
      "skills",
      "Skills",
      values.length,
      values.length ? "项目可读取的技能清单；展开单项查看说明。" : "该项目目前没有可读取的 Skill。"
    );
    var list = S.node("div", "project-skill-list");
    if (!values.length) {
      list.appendChild(S.node("div", "list-empty", "暂无 Skill。"));
    } else {
      values.forEach(function (skill) {
        var row = S.node("article", "skill-row");
        var heading = S.node("div", "skill-heading");
        var copy = S.node("div", "row-main");
        copy.appendChild(S.node("div", "row-title", skill.name || skill.skillID));
        if (skill.scope) copy.appendChild(S.node("div", "row-detail", "范围：" + skill.scope));
        heading.appendChild(S.icon("wand.and.stars", "skill-icon"));
        heading.appendChild(copy);
        if (skill.actionCount) heading.appendChild(S.badge("动作 " + skill.actionCount, "neutral"));
        row.appendChild(heading);
        if (skill.description) {
          row.appendChild(S.markdown(skill.description, "skill-description markdown-body", skill.descriptionHTML));
        } else {
          row.appendChild(S.node("p", "skill-description muted", "暂无说明。"));
        }
        list.appendChild(row);
      });
    }
    card.body.appendChild(list);
    container.appendChild(card.root);
  }

  function collectionCard(projectID, key, title, count, description) {
    var root = disclosure(projectID, key, "page-card project-collection-card");
    var summary = S.node("summary", "project-collection-summary");
    summary.appendChild(S.node("span", "project-collection-title", title));
    summary.appendChild(S.badge(String(count), "neutral"));
    root.appendChild(summary);
    var body = S.node("div", "project-collection-body");
    if (description) body.appendChild(S.node("p", "muted project-collection-description", description));
    root.appendChild(body);
    return { root: root, body: body };
  }

  function disclosure(projectID, key, className) {
    var root = S.node("details", className);
    var stateKey = String(projectID || "") + "|" + key;
    if (disclosureState.has(stateKey)) root.open = disclosureState.get(stateKey);
    root.addEventListener("toggle", function () { disclosureState.set(stateKey, root.open); });
    return root;
  }

  function groupSessions(sessions) {
    var groups = [], byProvider = new Map();
    sessions.forEach(function (session) {
      var key = session.providerID || session.provider || "unknown";
      var group = byProvider.get(key);
      if (!group) {
        group = { key: key, label: session.provider || session.providerID || "未知 Agent", sessions: [] };
        byProvider.set(key, group); groups.push(group);
      }
      group.sessions.push(session);
    });
    return groups;
  }

  function sessionRow(session, emit) {
    var row = S.node("div", "list-row session-row" + (session.selected ? " selected" : ""));
    var open = S.node("button", "session-open");
    open.type = "button";
    open.appendChild(S.icon("bubble.left.and.text.bubble.right.fill", "icon"));
    var copy = S.node("div", "row-main");
    copy.appendChild(S.node("div", "row-title", session.title || "未命名会话"));
    copy.appendChild(S.node("div", "row-detail", session.turnCount + " 轮 · " + session.status));
    open.appendChild(copy);
    open.addEventListener("click", function () { emit("selectTask", { taskID: session.taskID }); });
    row.appendChild(open);
    row.appendChild(S.badge(session.status || "未知", session.isRunning ? "running" : "neutral"));
    if (session.canDelete) {
      var remove = S.button("删除", null, {}, emit, "small danger", false);
      var confirmation = S.node("div", "agent-confirmation session-confirmation");
      var accept = S.button("确认删除", null, {}, emit, "small danger", false);
      var cancel = S.button("取消", null, {}, emit, "small", false);
      confirmation.hidden = true;
      confirmation.appendChild(S.node("span", null, "删除此会话的全部任务与记录？"));
      confirmation.appendChild(accept); confirmation.appendChild(cancel);
      remove.addEventListener("click", function () {
        remove.hidden = true; confirmation.hidden = false;
      });
      accept.addEventListener("click", function () {
        accept.disabled = true; cancel.disabled = true;
        emit("deleteSession", { taskID: session.taskID, sessionID: session.sessionID });
      });
      cancel.addEventListener("click", function () {
        confirmation.hidden = true; remove.hidden = false;
      });
      row.appendChild(remove);
      row.appendChild(confirmation);
    }
    return row;
  }

  function addValues(container, title, values, mono) {
    var card = S.node("div", "page-card");
    card.appendChild(S.node("h3", null, title));
    values.forEach(function (value) { card.appendChild(S.node("div", mono ? "page-message mono" : "page-message", value)); });
    container.appendChild(card);
  }

  global.CodexBridgeDesktopProjectCollections = { render: renderReadonlyCollections };
}(window));
