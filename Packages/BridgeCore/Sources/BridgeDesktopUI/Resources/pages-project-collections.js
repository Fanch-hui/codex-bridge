(function (global) {
  "use strict";
  var S = global.CodexBridgeDesktopPageSupport;
  var disclosureState = new Map(), pendingDeletes = new Set();

  function renderReadonlyCollections(container, page, emit, kind) {
    if (!kind || kind === "verification") addValues(container, page.verificationCommands);
    if (!kind || kind === "sessions") addSessionRows(container, page.sessions, page.selectedProjectID, emit);
    if (!kind || kind === "skills") addSkillRows(container, page.skills, page.selectedProjectID);
  }

  function addSessionRows(container, sessions, projectID, emit) {
    var values = S.safeArray(sessions);
    var active = new Set(values.map(function (session) { return deleteKey(projectID, session); }));
    pendingDeletes.forEach(function (key) { if (key.indexOf(String(projectID || "") + "|") === 0 && !active.has(key)) pendingDeletes.delete(key); });
    var root = S.node("div", "project-session-groups");
    if (!values.length) {
      root.appendChild(S.node("div", "project-pane-empty", "此项目还没有会话。"));
    } else {
      groupSessions(values).forEach(function (group) {
        var section = S.node("section", "project-session-group");
        var heading = S.node("div", "project-group-heading");
        heading.appendChild(S.node("h3", null, group.label));
        heading.appendChild(S.node("span", "muted", String(group.sessions.length)));
        section.appendChild(heading);
        var list = S.node("div", "project-session-list");
        group.sessions.forEach(function (session) { list.appendChild(sessionRow(session, projectID, emit)); });
        section.appendChild(list); root.appendChild(section);
      });
    }
    container.appendChild(root);
  }

  function addSkillRows(container, skills, projectID) {
    var values = S.safeArray(skills);
    var list = S.node("div", "project-skill-list");
    if (!values.length) {
      list.appendChild(S.node("div", "project-pane-empty", "此项目还没有技能。"));
    } else {
      values.forEach(function (skill) {
        var row = S.node("article", "skill-row");
        var heading = S.node("div", "skill-heading");
        var copy = S.node("div", "row-main");
        copy.appendChild(S.node("div", "row-title", skill.name || skill.skillID));
        if (skill.scope) copy.appendChild(S.node("div", "row-detail", skill.scope));
        heading.appendChild(copy);
        if (skill.actionCount) heading.appendChild(S.badge("动作 " + skill.actionCount, "neutral"));
        row.appendChild(heading);
        if (skill.description) {
          var description = disclosure(projectID, "skill:" + (skill.skillID || skill.name), "skill-description");
          description.appendChild(S.node("summary", "disclosure-summary", "说明"));
          description.appendChild(S.markdown(skill.description, "markdown-body", skill.descriptionHTML));
          row.appendChild(description);
        }
        list.appendChild(row);
      });
    }
    container.appendChild(list);
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

  function deleteKey(projectID, session) {
    return String(projectID || "") + "|" + String(session.sessionID || "") + "|" + String(session.taskID || "");
  }

  function sessionRow(session, projectID, emit) {
    var row = S.node("div", "list-row session-row" + (session.selected ? " selected" : ""));
    var open = S.node("button", "session-open");
    open.type = "button";
    open.appendChild(S.icon("bubble.left.and.text.bubble.right.fill", "icon"));
    var copy = S.node("div", "row-main");
    copy.appendChild(S.node("div", "row-title", session.title || "未命名会话"));
    open.appendChild(copy);
    open.addEventListener("click", function () { emit("openTask", { taskID: session.taskID }); });
    row.appendChild(open);
    var status = session.status || "未知";
    var tone = "neutral";
    if (session.isRunning) tone = "running";
    else if (/失败|failed/.test(status)) tone = "error";
    else if (/等待|审批|排队|queued|waiting|awaiting/.test(status)) tone = "warning";
    else if (/已完成|已创建|就绪|completed/.test(status)) tone = "success";
    row.appendChild(S.status(status, tone));
    if (session.canDelete) {
      var remove = S.button("删除", null, {}, emit, "small danger", false);
      var confirmation = S.node("div", "agent-confirmation session-confirmation");
      var accept = S.button("确认删除", null, {}, emit, "small danger", false);
      var cancel = S.button("取消", null, {}, emit, "small", false);
      var key = deleteKey(projectID, session);
      confirmation.hidden = !pendingDeletes.has(key);
      remove.hidden = pendingDeletes.has(key);
      confirmation.appendChild(S.node("span", null, "删除此会话的全部任务与记录？"));
      confirmation.appendChild(accept); confirmation.appendChild(cancel);
      remove.addEventListener("click", function () {
        pendingDeletes.add(key);
        remove.hidden = true; confirmation.hidden = false;
      });
      accept.addEventListener("click", function () {
        pendingDeletes.add(key);
        accept.disabled = true; cancel.disabled = true;
        emit("deleteSession", { taskID: session.taskID, sessionID: session.sessionID });
      });
      cancel.addEventListener("click", function () {
        pendingDeletes.delete(key);
        confirmation.hidden = true; remove.hidden = false;
      });
      row.appendChild(remove);
      row.appendChild(confirmation);
    }
    return row;
  }

  function addValues(container, values) {
    if (!S.safeArray(values).length) return;
    var section = S.node("section", "project-verification-commands");
    section.appendChild(S.node("h3", null, "验证命令"));
    values.forEach(function (value) { section.appendChild(S.node("pre", "project-command mono", value)); });
    container.appendChild(section);
  }

  global.CodexBridgeDesktopProjectCollections = { render: renderReadonlyCollections };
}(window));
