(function (global) {
  "use strict";

  var S = global.CodexBridgeDesktopPageSupport;
  var shell = null, details = new Map();
  var context = { page: null, emit: null };

  function createShell(container) {
    var header = S.node("div"), toolbar = S.node("div", "page-toolbar");
    var add = S.button("添加项目", null, {}, null, "primary");
    add.addEventListener("click", function () { context.emit("registerProject", {}); });
    toolbar.appendChild(S.node("span", "muted", "只有明确注册的本地目录才会暴露给 MCP 客户端。"));
    toolbar.appendChild(S.node("span", "toolbar-spacer")); toolbar.appendChild(add);
    var layout = S.node("div", "split-layout"), list = S.node("section", "list-panel");
    var detailHost = S.node("div", "project-detail-host"), empty = S.node("section", "detail-panel");
    S.empty(empty, "请选择一个项目", "从左侧列表选择目录后，可以配置访问权限和 Direct 命令。");
    detailHost.appendChild(empty); layout.appendChild(list); layout.appendChild(detailHost);
    container.appendChild(header); container.appendChild(toolbar); container.appendChild(layout);
    return { header: header, add: add, layout: layout, list: list, detailHost: detailHost, empty: empty };
  }

  function render(page, emit) {
    context.page = page; context.emit = emit;
    if (!shell) shell = createShell(document.getElementById("projects-content"));
    S.pageHeader(shell.header, page ? page.header : {
      title: "项目", subtitle: "正在从本机 Service 读取项目状态。", symbol: "folder.fill"
    });
    shell.add.disabled = !page || !page.canRegister;
    if (!page) {
      details.forEach(function (detail) { detail.setAvailable(false); });
      return;
    }
    renderList(page);
    var selected = S.safeArray(page.rows).find(function (row) { return row.projectID === page.selectedProjectID; });
    shell.empty.hidden = !!selected;
    details.forEach(function (detail, id) { detail.root.hidden = !selected || id !== selected.projectID; });
    if (!selected) return;
    var detail = details.get(selected.projectID);
    if (!detail) {
      detail = createDetail(selected.projectID);
      details.set(selected.projectID, detail);
      shell.detailHost.appendChild(detail.root);
    }
    detail.root.hidden = false;
    detail.update(page, selected, emit);
  }

  function renderList(page) {
    S.clear(shell.list);
    var header = S.node("div", "list-panel-header"), copy = S.node("div");
    copy.appendChild(S.node("h3", null, "已注册项目"));
    copy.appendChild(S.node("p", null, "共 " + S.safeArray(page.rows).length + " 个目录"));
    header.appendChild(copy); shell.list.appendChild(header);
    var body = S.node("div", "list-body");
    S.safeArray(page.rows).forEach(function (project) {
      var row = S.node("button", "project-row" + (project.selected ? " selected" : ""));
      row.type = "button"; row.appendChild(S.icon("folder.fill", "service-icon"));
      var text = S.node("div", "row-main");
      text.appendChild(S.node("div", "row-title", project.name));
      text.appendChild(S.node("div", "row-detail", project.detail || project.projectID));
      row.appendChild(text); row.appendChild(S.badge(project.gitState || "未检查", project.gitState ? "success" : "neutral"));
      row.addEventListener("click", function () { context.emit("selectProject", { projectID: project.projectID }); });
      body.appendChild(row);
    });
    if (!S.safeArray(page.rows).length) body.appendChild(S.node("div", "list-empty", "尚未注册项目。"));
    shell.list.appendChild(body);
  }

  function createDetail(projectID) {
    var current = { project: null, emit: null };
    var root = S.node("section", "detail-panel"), header = S.node("div", "detail-panel-header");
    var title = S.node("div"), name = S.node("h3");
    title.appendChild(name); title.appendChild(S.node("p", "muted mono", projectID)); header.appendChild(title);
    var remove = S.button("移除项目", null, {}, null, "small danger", true);
    remove.addEventListener("click", function () {
      if (remove.disabled || !global.confirm("从 Codex Bridge 移除项目“" + current.project.name + "”？\n本地磁盘文件不会受到影响。")) return;
      current.emit("removeProject", { projectID: projectID });
    });
    header.appendChild(remove); root.appendChild(header);
    var body = S.node("div", "detail-body"), description = S.node("p", "muted");
    var policy = global.CodexBridgeDesktopProjectEditors.policy(projectID);
    var workspace = global.CodexBridgeDesktopProjectWorkspace.create(projectID);
    var collections = S.node("div");
    body.appendChild(description); body.appendChild(policy.root); body.appendChild(workspace.root);
    body.appendChild(collections); root.appendChild(body);
    return {
      root: root,
      setAvailable: function (available) {
        remove.disabled = !available; policy.setAvailable(available); workspace.setAvailable(available);
      },
      update: function (page, project, emit) {
        current.project = project; current.emit = emit;
        name.textContent = project.name; description.textContent = page.selectedProjectDetail || "";
        description.hidden = !page.selectedProjectDetail; remove.disabled = !page.canRemove;
        policy.update(page, project, emit);
        workspace.root.hidden = !page.workspace;
        workspace.update(page.workspace, emit);
        S.clear(collections);
        global.CodexBridgeDesktopProjectCollections.render(collections, page, emit);
      }
    };
  }

  global.CodexBridgeDesktopProjectsPage = { render: render };
}(window));
