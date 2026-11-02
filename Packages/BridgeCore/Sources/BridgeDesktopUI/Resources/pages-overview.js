(function (global) {
  "use strict";
  var S = global.CodexBridgeDesktopPageSupport, shell;
  var currentEmit;

  function stable(container, value, render) {
    if (global.CodexBridgeDesktopStableRender) {
      global.CodexBridgeDesktopStableRender(container, JSON.stringify(value), render);
    } else render();
  }

  function createShell() {
    var root = S.node("div", "activity-workspace");
    var feed = S.node("div", "activity-feed"), sidebar = S.node("aside", "activity-connections");
    sidebar.setAttribute("aria-label", "连接状态");
    var pending = section("需要处理"), recent = section("最近会话");
    var update = S.node("div"); update.id = "app-update"; update.hidden = true;
    update.setAttribute("aria-live", "polite");
    pending.body.appendChild(update);
    var notices = S.node("div", "activity-notices"); notices.setAttribute("aria-live", "polite");
    pending.body.appendChild(notices);
    var start = S.button("新建对话", null, {}, null, "small");
    start.addEventListener("click", function () { global.CodexBridgeDesktopDSHWorkbench.openConversation(); });
    recent.header.appendChild(start);
    var tasks = S.node("div", "activity-sessions"); recent.body.appendChild(tasks);
    var next = S.node("div", "activity-next-actions"); recent.body.appendChild(next);
    feed.appendChild(pending.root); feed.appendChild(recent.root);
    var connectionHeader = S.node("div", "activity-section-heading");
    connectionHeader.appendChild(S.node("h2", null, "连接"));
    connectionHeader.appendChild(S.button("管理", "openConnections", {}, function (command, payload) {
      currentEmit(command, payload);
    }, "link-button small"));
    sidebar.appendChild(connectionHeader);
    var services = S.node("div", "activity-service-list"), actions = S.node("div", "activity-service-actions");
    sidebar.appendChild(services); sidebar.appendChild(actions);
    root.appendChild(feed); root.appendChild(sidebar);
    document.getElementById("overview-content").appendChild(root);
    return { pending: pending.root, update: update, notices: notices, tasks: tasks,
      next: next, services: services, actions: actions };
  }

  function section(title) {
    var root = S.node("section", "activity-section"), header = S.node("div", "activity-section-heading");
    header.appendChild(S.node("h2", null, title)); root.appendChild(header);
    var body = S.node("div", "activity-section-body"); root.appendChild(body);
    return { root: root, header: header, body: body };
  }

  function openDestination(destination, detailID, options) {
    var connections = global.CodexBridgeDesktopConnectionsPage;
    if (destination === "connections" && detailID && connections && connections.openDetail) {
      connections.openDetail(detailID, currentEmit, options);
    } else currentEmit("selectPage", { navigation: destination });
  }

  function renderServices(rows, actions) {
    stable(shell.services, rows, function () {
      S.clear(shell.services);
      S.safeArray(rows).forEach(function (row) {
        var element = S.node(row.destination ? "button" : "div", "activity-service");
        if (row.destination) {
          element.type = "button";
          element.addEventListener("click", function () {
            var id = { "openai.chatgpt": "chatgpt", "qwen.studio": "qwen", "google.gemini": "gemini" }[row.id] || row.id;
            openDestination(row.destination, id);
          });
        }
        element.appendChild(S.node("span", null, row.title));
        element.appendChild(S.status(row.value, row.tone)); shell.services.appendChild(element);
      });
      if (!shell.services.children.length) shell.services.appendChild(S.node("p", "muted", "还没有连接。"));
    });
    stable(shell.actions, actions, function () {
      S.clear(shell.actions);
      S.safeArray(actions).forEach(function (action) { shell.actions.appendChild(actionButton(action)); });
    });
  }

  function actionButton(action) {
    return S.button(action.title, action.command, {
      navigation: action.destination || null, taskID: action.taskID || null
    }, function (command, payload) { currentEmit(command, payload); }, "link-button small");
  }

  function taskTone(status) {
    if (["completed", "已完成", "已创建"].includes(status)) return "success";
    if (["failed", "失败"].includes(status)) return "error";
    if (["running", "starting", "运行中", "正在启动"].includes(status)) return "running";
    return /approval|等待|审批/.test(status) ? "warning" : "neutral";
  }

  function renderRecentTasks(tasks) {
    stable(shell.tasks, tasks, function () {
      S.clear(shell.tasks);
      S.safeArray(tasks).slice(0, 4).forEach(function (task) {
        var row = S.node("button", "activity-session"); row.type = "button";
        var copy = S.node("span", "activity-session-copy");
        copy.appendChild(S.node("span", "activity-session-title", task.title));
        copy.appendChild(S.node("span", "activity-session-meta", [task.projectName, task.source].filter(Boolean).join(" · ")));
        row.appendChild(copy); row.appendChild(S.status(task.status, taskTone(task.status)));
        row.appendChild(S.node("span", "activity-session-time", task.updatedAt));
        row.addEventListener("click", function () { currentEmit("openTask", { taskID: task.id }); });
        shell.tasks.appendChild(row);
      });
      if (!shell.tasks.children.length) {
        var empty = S.node("div", "activity-empty");
        empty.appendChild(S.node("h3", null, "从一段对话开始"));
        empty.appendChild(S.node("p", null, "在工作台连接模型，或在网页工作台中使用已连接的 Agent。"));
        shell.tasks.appendChild(empty);
      }
    });
  }

  function renderNotices(notices) {
    stable(shell.notices, notices, function () {
      S.clear(shell.notices);
      S.safeArray(notices).forEach(function (notice) {
        var element = S.node("div", "activity-notice tone-" + (notice.tone || "neutral"));
        element.appendChild(S.icon(notice.symbol));
        var copy = S.node("div", "activity-notice-copy");
        copy.appendChild(S.node("h3", null, notice.title));
        if (notice.message) copy.appendChild(S.node("p", null, notice.message));
        element.appendChild(copy);
        if (notice.command || notice.destination) {
          var action = S.button(notice.command === "openSystemSettings" ? "打开登录项设置" : "查看", null, {}, null, "small");
          action.addEventListener("click", function () {
            if (notice.command) currentEmit(notice.command, { navigation: notice.destination || null });
            else openDestination(notice.destination, notice.detailID, {
              distribution: notice.distribution, installationID: notice.installationID
            });
          });
          element.appendChild(action);
        }
        shell.notices.appendChild(element);
      });
    });
  }

  function render(overview, updateState, emit) {
    currentEmit = emit;
    if (!shell) shell = createShell();
    if (!overview) return;
    renderServices(overview.clientConnections || overview.services, overview.serviceActions);
    renderRecentTasks(overview.recentTasks); renderNotices(overview.notices);
    stable(shell.next, overview.onboardingSteps, function () {
      S.clear(shell.next);
      S.safeArray(overview.onboardingSteps).forEach(function (step) { shell.next.appendChild(actionButton(step)); });
    });
    if (global.CodexBridgeDesktopAppUpdate) global.CodexBridgeDesktopAppUpdate.renderOverview(shell.update, updateState, emit);
    shell.pending.hidden = !S.safeArray(overview.notices).length && shell.update.hidden;
  }

  global.CodexBridgeDesktopOverviewPage = { render: render };
}(window));
