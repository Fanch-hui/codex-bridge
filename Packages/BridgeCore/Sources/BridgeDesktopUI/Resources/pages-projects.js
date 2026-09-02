(function (global) {
  "use strict";

  var S = global.CodexBridgeDesktopPageSupport;

  function render(page, emit) {
    var container = document.getElementById("projects-content");
    S.clear(container);
    if (!page) {
      var unavailableHeader = S.node("div");
      S.pageHeader(unavailableHeader, { title: "项目", subtitle: "正在从本机 Service 读取项目状态。", symbol: "folder.fill" });
      container.appendChild(unavailableHeader);
      var unavailable = S.node("div");
      S.empty(unavailable, "项目页暂不可用", "连接本机 Service 后，可以管理注册目录与 Direct 策略。");
      container.appendChild(unavailable);
      return;
    }
    var header = S.node("div");
    S.pageHeader(header, page.header);
    container.appendChild(header);
    var toolbar = S.node("div", "page-toolbar");
    toolbar.appendChild(S.node("span", "muted", "只有明确注册的本地目录才会暴露给 MCP 客户端。"));
    toolbar.appendChild(S.node("span", "toolbar-spacer"));
    toolbar.appendChild(S.button("添加项目", "registerProject", {}, emit, "primary", !page.canRegister));
    container.appendChild(toolbar);
    var layout = S.node("div", "split-layout");
    layout.appendChild(projectList(page, emit));
    layout.appendChild(projectDetail(page, emit));
    container.appendChild(layout);
  }

  function projectList(page, emit) {
    var panel = S.node("section", "list-panel");
    var header = S.node("div", "list-panel-header");
    var copy = S.node("div");
    copy.appendChild(S.node("h3", null, "已注册项目"));
    copy.appendChild(S.node("p", null, "共 " + (page.rows || []).length + " 个目录"));
    header.appendChild(copy);
    panel.appendChild(header);
    var body = S.node("div", "list-body");
    S.safeArray(page.rows).forEach(function (project) {
      var row = S.node("button", "project-row" + (project.selected ? " selected" : ""));
      row.type = "button";
      row.appendChild(S.icon("folder.fill", "service-icon"));
      var main = S.node("div", "row-main");
      main.appendChild(S.node("div", "row-title", project.name));
      main.appendChild(S.node("div", "row-detail", project.detail || project.projectID));
      row.appendChild(main);
      row.appendChild(S.badge(project.gitState || "未检查", project.gitState ? "success" : "neutral"));
      row.addEventListener("click", function () { emit("selectProject", { projectID: project.projectID }); });
      body.appendChild(row);
    });
    if (!page.rows || page.rows.length === 0) body.appendChild(S.node("div", "list-empty", "尚未注册项目。"));
    panel.appendChild(body);
    return panel;
  }

  function projectDetail(page, emit) {
    var panel = S.node("section", "detail-panel");
    var selected = S.safeArray(page.rows).find(function (row) { return row.projectID === page.selectedProjectID; });
    if (!selected) {
      S.empty(panel, "请选择一个项目", "从左侧列表选择目录后，可以配置访问权限和 Direct 命令。");
      return panel;
    }
    var header = S.node("div", "detail-panel-header");
    var title = S.node("div");
    title.appendChild(S.node("h3", null, selected.name));
    title.appendChild(S.node("p", "muted mono", selected.projectID));
    header.appendChild(title);
    var removeProject = S.button("移除项目", null, {}, emit, "small danger", !page.canRemove);
    removeProject.addEventListener("click", function () {
      if (global.confirm("从 Codex Bridge 移除项目“" + selected.name + "”？\n本地磁盘文件不会受到影响。")) {
        emit("removeProject", { projectID: selected.projectID });
      }
    });
    header.appendChild(removeProject);
    panel.appendChild(header);
    var body = S.node("div", "detail-body");
    if (page.selectedProjectDetail) body.appendChild(S.node("p", "muted", page.selectedProjectDetail));
    renderPolicy(body, page, selected, emit);
    if (page.workspace) renderWorkspace(body, page.workspace, selected.projectID, emit);
    renderReadonlyCollections(body, page, emit);
    panel.appendChild(body);
    return panel;
  }

  function renderPolicy(container, page, project, emit) {
    var card = S.node("div", "page-card");
    card.appendChild(S.node("h3", null, "访问与执行权限"));
    var grid = S.node("div", "form-grid three");
    var read = S.selectField("读取", project.readPermission, S.choices(project.readPermission, page.readOptions.length ? page.readOptions : page.policyOptions), function () {}, "");
    var write = S.selectField("写入", project.writePermission, S.choices(project.writePermission, page.writeOptions.length ? page.writeOptions : page.policyOptions), function () {}, "");
    var network = S.selectField("网络", project.networkPermission, S.choices(project.networkPermission, page.networkOptions.length ? page.networkOptions : page.policyOptions), function () {}, "");
    grid.appendChild(read.wrapper);
    grid.appendChild(write.wrapper);
    grid.appendChild(network.wrapper);
    card.appendChild(grid);
    var actions = S.node("div", "form-actions");
    actions.appendChild(S.button("保存权限", null, {}, emit, "small primary", !page.canSavePolicy));
    actions.firstChild.addEventListener("click", function () {
      emit("saveProjectPolicy", { projectID: project.projectID, readPermission: read.control.value, writePermission: write.control.value, networkPermission: network.control.value });
    });
    card.appendChild(actions);
    container.appendChild(card);
  }

  function renderWorkspace(container, workspace, projectID, emit) {
    var card = S.node("div", "page-card");
    card.appendChild(S.node("h3", null, "Direct 工作区"));
    var mode = S.selectField("命令模式", workspace.commandMode, S.choices(workspace.commandMode, workspace.commandModeOptions), function () {}, "");
    card.appendChild(mode.wrapper);
    var modeActions = S.node("div", "form-actions");
    var saveMode = S.button("保存命令模式", null, {}, emit, "small", !workspace.canSaveMode);
    saveMode.addEventListener("click", function () {
      emit("setProjectCommandMode", { projectID: projectID, mode: mode.control.value });
    });
    modeActions.appendChild(saveMode);
    card.appendChild(modeActions);
    var commandTitle = S.node("div", "section-heading-row");
    commandTitle.appendChild(S.node("h4", null, "已登记命令"));
    var newButton = S.button("新建命令", null, {}, emit, "small", !workspace.canSaveCommand);
    commandTitle.appendChild(newButton);
    card.appendChild(commandTitle);
    var commandList = S.node("div", "list-body");
    S.safeArray(workspace.commands).forEach(function (command, index) {
      var row = S.node("button", "list-row");
      row.type = "button";
      row.appendChild(S.icon("terminal", "icon"));
      var copy = S.node("div", "row-main");
      copy.appendChild(S.node("div", "row-title", command.name));
      copy.appendChild(S.node("div", "row-detail mono", command.executable + " " + command.arguments.join(" ")));
      row.appendChild(copy);
      row.addEventListener("click", function () { renderWorkspaceBody(card, workspace, projectID, emit, index); });
      commandList.appendChild(row);
    });
    if (!workspace.commands || workspace.commands.length === 0) commandList.appendChild(S.node("div", "list-empty", "暂无已登记命令。"));
    card.appendChild(commandList);
    var form = commandForm(workspace.commands && workspace.commands[0], workspace, projectID, emit);
    card.appendChild(form.wrapper);
    newButton.addEventListener("click", function () { renderWorkspaceBody(card, workspace, projectID, emit, -1); });
    renderBlacklist(card, workspace, projectID, emit);
    container.appendChild(card);
  }

  function renderWorkspaceBody(card, workspace, projectID, emit, index) {
    var old = card.querySelector(".command-editor");
    if (old) old.remove();
    var command = index >= 0 ? workspace.commands[index] : null;
    card.appendChild(commandForm(command, workspace, projectID, emit).wrapper);
  }

  function commandForm(command, workspace, projectID, emit) {
    var wrapper = S.node("div", "command-editor page-message");
    var grid = S.node("div", "form-grid");
    var name = S.textField("名称", command ? command.name : "", "例如：测试");
    var executable = S.textField("可执行文件", command ? command.executable : "", "例如：swift");
    var args = multilineField("参数（每行一个参数）", command ? command.arguments.join("\n") : "", "例如：--configuration\npath with spaces");
    var cwd = S.textField("工作目录", command ? command.workingDirectory : "", "可选");
    var risk = S.selectField("风险等级", command ? command.risk : "normal", [
      { id: "normal", title: "普通" }, { id: "elevated", title: "高风险" }
    ], function () {}, "");
    [name, executable, args, cwd, risk].forEach(function (field) { grid.appendChild(field.wrapper); });
    var network = S.node("label", "check-field");
    var checkbox = S.node("input");
    checkbox.type = "checkbox";
    checkbox.checked = !!(command && command.requiresNetwork);
    network.appendChild(checkbox);
    network.appendChild(S.node("span", null, "需要网络"));
    grid.appendChild(network);
    wrapper.appendChild(grid);
    var actions = S.node("div", "form-actions");
    var save = S.button("保存命令", null, {}, emit, "small primary", !workspace.canSaveCommand);
    save.addEventListener("click", function () {
      emit("saveProjectCommand", { projectID: projectID, commandID: command ? command.commandID : null, name: name.control.value, executable: executable.control.value, arguments: splitLines(args.control.value), workingDirectory: cwd.control.value || null, requiresNetwork: checkbox.checked, risk: risk.control.value || "normal" });
    });
    actions.appendChild(save);
    if (command) {
      var remove = S.button("删除命令", null, {}, emit, "small danger", !workspace.canRemoveCommand);
      remove.addEventListener("click", function () {
        if (global.confirm("删除 Direct 命令“" + command.name + "”？")) emit("removeProjectCommand", { projectID: projectID, commandID: command.commandID });
      });
      actions.appendChild(remove);
    }
    wrapper.appendChild(actions);
    return { wrapper: wrapper };
  }

  function multilineField(label, value, placeholder) {
    var wrapper = S.node("div", "field full");
    wrapper.appendChild(S.node("label", null, label));
    var control = S.node("textarea");
    control.value = value || "";
    control.placeholder = placeholder || "";
    wrapper.appendChild(control);
    return { wrapper: wrapper, control: control };
  }

  function splitLines(value) {
    return (value || "").split(/\r?\n/).map(function (line) { return line.trim(); }).filter(Boolean);
  }

  function renderBlacklist(card, workspace, projectID, emit) {
    var title = S.node("div", "section-heading-row");
    title.appendChild(S.node("h4", null, "命令黑名单"));
    title.appendChild(S.button("新增规则", null, {}, emit, "small", !workspace.canSaveBlacklist));
    card.appendChild(title);
    var list = S.node("div", "list-body");
    S.safeArray(workspace.blacklist).forEach(function (rule, index) {
      var row = S.node("button", "list-row");
      row.type = "button";
      row.appendChild(S.icon("shield.lefthalf.filled", "icon"));
      row.appendChild(S.node("span", "row-main mono", rule.executable || rule.pattern || rule.ruleID));
      row.addEventListener("click", function () { renderBlacklistBody(card, workspace, projectID, emit, index); });
      list.appendChild(row);
    });
    if (!workspace.blacklist || workspace.blacklist.length === 0) list.appendChild(S.node("div", "list-empty", "暂无黑名单规则。"));
    card.appendChild(list);
    var add = title.lastChild;
    add.addEventListener("click", function () { renderBlacklistBody(card, workspace, projectID, emit, -1); });
    card.appendChild(blacklistForm(null, workspace, projectID, emit).wrapper);
  }

  function renderBlacklistBody(card, workspace, projectID, emit, index) {
    var old = card.querySelector(".blacklist-editor");
    if (old) old.remove();
    var rule = index >= 0 ? workspace.blacklist[index] : null;
    card.appendChild(blacklistForm(rule, workspace, projectID, emit).wrapper);
  }

  function blacklistForm(rule, workspace, projectID, emit) {
    var wrapper = S.node("div", "blacklist-editor page-message");
    var grid = S.node("div", "form-grid");
    var executable = S.textField("可执行文件", rule ? rule.executable : "", "可选");
    var pattern = S.textField("匹配模式", rule ? rule.pattern : "", "可选");
    [executable, pattern].forEach(function (field) { grid.appendChild(field.wrapper); });
    wrapper.appendChild(grid);
    var actions = S.node("div", "form-actions");
    var save = S.button("保存规则", null, {}, emit, "small primary", !workspace.canSaveBlacklist);
    save.addEventListener("click", function () {
      emit("saveProjectBlacklist", { projectID: projectID, ruleID: rule ? rule.ruleID : null, executable: executable.control.value || null, pattern: pattern.control.value || null });
    });
    actions.appendChild(save);
    if (rule) {
      var remove = S.button("删除规则", null, {}, emit, "small danger", !workspace.canRemoveBlacklist);
      remove.addEventListener("click", function () {
        if (global.confirm("删除这条 Direct 命令黑名单规则？")) emit("removeProjectBlacklist", { projectID: projectID, ruleID: rule.ruleID });
      });
      actions.appendChild(remove);
    }
    wrapper.appendChild(actions);
    return { wrapper: wrapper };
  }

  function renderReadonlyCollections(container, page, emit) {
    if (page.verificationCommands && page.verificationCommands.length) addValues(container, "验证命令", page.verificationCommands, true);
    addRows(container, "Codex Threads", page.threads, "threadID", function (thread) {
      emit("openThread", { threadID: thread.threadID, projectID: page.selectedProjectID });
    });
    addRows(container, "Skills", page.skills, "skillID");
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

  global.CodexBridgeDesktopProjectsPage = { render: render };
}(window));
