(function (global) {
  "use strict";
  var S = global.CodexBridgeDesktopPageSupport;
  var searchMatch = null, rendered = null;

  function reveal(sessionID, messageID) {
    searchMatch = sessionID && messageID ? { sessionID: sessionID, messageID: messageID } : null;
  }

  function emit(emitCommand, action, state, sessionID, extra) {
    var payload = Object.assign({
      action: action,
      projectID: state.projectID,
      installationID: state.installationID,
      sessionID: sessionID || null
    }, extra || {});
    emitCommand("manageNativeAgentSession", payload);
  }

  // Everything the panel draws or captures in its handlers; an unchanged panel keeps its DOM
  // (and the installation choice being made) instead of being rebuilt by every patch.
  function renderInputs(page, state, emitCommand) {
    return [state, page.selectedProjectID, emitCommand, searchMatch, !!(searchMatch && searchMatch.revealed)];
  }

  function render(page, emitCommand) {
    var container = document.getElementById("workbench-native-sessions");
    var state = page && page.nativeSessions;
    container.hidden = !state || !state.isOpen;
    if (container.hidden) return;
    if (searchMatch && state.selectedSessionID && state.selectedSessionID !== searchMatch.sessionID) {
      searchMatch = null;
    }
    var inputs = renderInputs(page, state, emitCommand);
    if (rendered && inputs.every(function (value, index) { return value === rendered[index]; })) return;
    S.clear(container);
    var header = S.node("div", "native-session-header");
    header.appendChild(S.node("h3", null, "Agent 原生会话"));
    header.appendChild(S.button("关闭", null, {}, null, "small", false));
    header.lastChild.addEventListener("click", function () {
      emitCommand("manageNativeAgentSession", { action: "close" });
    });
    container.appendChild(header);

    var controls = S.node("div", "native-session-controls");
    var installation = S.node("select", "native-session-installation");
    installation.setAttribute("aria-label", "Agent 安装与地区");
    S.safeArray(state.installations).forEach(function (item) {
      var option = S.node("option", null, item.displayName + (item.region ? " · " + item.region : ""));
      option.value = item.installationID;
      installation.appendChild(option);
    });
    installation.value = state.installationID || (state.installations[0] && state.installations[0].installationID) || "";
    installation.addEventListener("change", function () {
      var projectID = state.projectID || page.selectedProjectID;
      if (!projectID || !installation.value) return;
      emitCommand("manageNativeAgentSession", {
        action: "list", projectID: projectID, installationID: installation.value, offset: 0, limit: 50
      });
    });
    controls.appendChild(installation);
    controls.appendChild(S.button("刷新", null, {}, null, "small", state.isLoading || !installation.value));
    controls.lastChild.addEventListener("click", function () {
      if (!installation.value) return;
      emitCommand("manageNativeAgentSession", {
        action: "list", projectID: state.projectID || page.selectedProjectID,
        installationID: installation.value, offset: 0, limit: 50
      });
    });
    container.appendChild(controls);
    if (state.isLoading) container.appendChild(S.node("p", "muted", "正在读取…"));
    if (state.statusMessage) container.appendChild(S.node("p", "native-session-status", state.statusMessage));
    if (state.errorMessage) container.appendChild(S.node("p", "native-session-error", state.errorMessage));

    var selected = S.safeArray(state.installations).find(function (item) { return item.installationID === state.installationID; });
    var legacy = selected && (selected.providerID === "pi" || selected.providerID === "qoder");
    var operations = selected && selected.operations
      || (legacy ? ["list", "read", "index", "rename", "delete", "continue"] : []);
    function supports(operation) { return operations.indexOf(operation) >= 0; }
    var list = S.node("div", "native-session-list");
    S.safeArray(state.sessions).forEach(function (session) {
      var row = S.node("article", "native-session-row");
      row.appendChild(S.node("h4", null, session.title || "未命名会话"));
      if (session.first_prompt) row.appendChild(S.node("p", "native-session-prompt", session.first_prompt));
      var meta = session.message_count == null ? "消息数未知" : session.message_count + " 条消息";
      if (session.updated_at) meta += " · " + formatNativeDate(session.updated_at);
      if (session.is_indexed) meta += " · 已导入";
      row.appendChild(S.node("p", "native-session-meta", meta));
      var actions = S.node("div", "native-session-actions");
      if (supports("read")) {
      var readBtn = S.button("查看", null, {}, null, "small", state.isLoading);
      readBtn.addEventListener("click", function () {
        S.setButtonPending(readBtn, true, "读取中…", "查看");
        emit(emitCommand, "read", state, session.session_id, { offset: 0, limit: 50 });
      });
      actions.appendChild(readBtn);
      }
      if (supports("index")) {
      var indexBtn = S.button(session.is_indexed ? "已导入" : "导入续写", null, {}, null, "small", session.is_indexed || state.isLoading);
      indexBtn.addEventListener("click", function () {
        S.setButtonPending(indexBtn, true, "导入中…", "导入续写");
        emit(emitCommand, "index", state, session.session_id);
      });
      actions.appendChild(indexBtn);
      }
      if (supports("rename")) {
      var renameBtn = S.button("重命名", null, {}, null, "small", state.isLoading);
      renameBtn.addEventListener("click", function () {
        S.promptDialog({
          title: "重命名原生会话",
          label: "会话名称",
          initialValue: session.title || "",
          placeholder: "输入新的会话名称",
          submitTitle: "保存"
        }).then(function (title) {
          if (title == null || !title.trim()) return;
          S.setButtonPending(renameBtn, true, "保存中…", "重命名");
          emit(emitCommand, "rename", state, session.session_id, { name: title.trim() });
        });
      });
      actions.appendChild(renameBtn);
      }
      if (supports("delete")) {
      var deleteBtn = S.button("删除原生会话", null, {}, null, "small danger", state.isLoading);
      deleteBtn.addEventListener("click", function () {
        if (!global.confirm("这会通过 Agent 官方接口永久删除原生会话，无法撤销。继续吗？")) return;
        S.setButtonPending(deleteBtn, true, "删除中…", "删除原生会话");
        emit(emitCommand, "delete", state, session.session_id, { confirmed: true });
      });
      actions.appendChild(deleteBtn);
      }
      if (supports("open")) {
        actions.appendChild(S.button("打开对应会话", "openDeepSeekHarnessSession", {
          projectID: state.projectID, installationID: state.installationID, sessionID: session.session_id
        }, emitCommand, "small", state.isLoading));
      }
      if (session.is_indexed && supports("continue")) {
        var continueBtn = S.button("续写", null, {}, null, "small primary", state.isLoading);
        continueBtn.addEventListener("click", function () {
          S.promptDialog({
            title: "续写原生会话",
            label: "续写指令",
            placeholder: "输入要继续交给 Agent 的内容…",
            multiline: true,
            submitTitle: "发送"
          }).then(function (prompt) {
            if (prompt == null || !prompt.trim()) return;
            var selectedInstallation = S.safeArray(state.installations).find(function (item) {
              return item.installationID === state.installationID;
            });
            if (!selectedInstallation) return;
            S.setButtonPending(continueBtn, true, "发送中…", "续写");
            emitCommand("continueNativeAgentSession", {
              projectID: state.projectID, providerID: selectedInstallation.providerID,
              installationID: state.installationID, sessionID: session.session_id, input: prompt.trim()
            });
          });
        });
        actions.appendChild(continueBtn);
      }
      row.appendChild(actions);
      list.appendChild(row);
    });
    container.appendChild(list);
    if (state.nextOffset != null) {
      var more = S.button("加载更多会话", null, {}, null, "small", state.isLoading);
      more.addEventListener("click", function () {
        emitCommand("manageNativeAgentSession", {
          action: "list", projectID: state.projectID, installationID: state.installationID,
          offset: state.nextOffset, limit: 50
        });
      });
      container.appendChild(more);
    }
    renderTranscript(container, page, state, emitCommand);
    rendered = renderInputs(page, state, emitCommand);
  }

  function renderTranscript(container, page, state, emitCommand) {
    if (!state.selectedSessionID || !state.transcript.length) return;
    var card = S.node("section", "native-session-transcript");
    card.appendChild(S.node("h4", null, "会话内容"));
    state.transcript.forEach(function (message) {
      var row = S.node("article", "native-session-message");
      row.appendChild(S.node("strong", null, message.role));
      row.appendChild(S.node("p", null, message.content));
      card.appendChild(row);
      if (searchMatch && state.selectedSessionID === searchMatch.sessionID
        && message.message_id === searchMatch.messageID) {
        row.classList.add("is-search-match");
        if (!state.isLoading && !searchMatch.revealed) {
          searchMatch.revealed = true;
          global.requestAnimationFrame(function () { row.scrollIntoView({ block: "center" }); });
        }
      }
    });
    if (state.transcriptNextOffset != null) {
      var more = S.button("读取更早内容", null, {}, null, "small", state.isLoading);
      more.addEventListener("click", function () {
        emit(emitCommand, "read", state, state.selectedSessionID, {
          offset: state.transcriptNextOffset, limit: 50
        });
      });
      card.appendChild(more);
    }
    container.appendChild(card);
  }

  function formatNativeDate(value) {
    var date = typeof value === "number"
      ? new Date((value + 978307200) * 1000)
      : new Date(value);
    return isNaN(date.getTime()) ? "" : date.toLocaleString();
  }

  global.CodexBridgeDesktopNativeSessionDirectory = { render: render, reveal: reveal };
}(window));
