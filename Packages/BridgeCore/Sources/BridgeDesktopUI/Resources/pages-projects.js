(function (global) {
  "use strict";
  var S = global.CodexBridgeDesktopPageSupport, shell;
  var details = new Map(), detailSequence = 0;
  var context = { page: null, emit: null, filter: "" };

  function createShell() {
    var root = S.node("div", "project-library"), library = S.node("aside", "project-library-sidebar");
    library.setAttribute("aria-label", "工作文件夹");
    var toolbar = S.node("div", "project-library-toolbar");
    var search = S.node("input", "project-library-search");
    search.type = "search"; search.placeholder = "查找项目"; search.setAttribute("aria-label", "查找项目");
    search.addEventListener("input", function () { context.filter = search.value; renderList(); });
    var add = S.button("打开文件夹…", null, {}, null, "small");
    add.addEventListener("click", function () { context.emit("registerProject", {}); });
    toolbar.appendChild(search); toolbar.appendChild(add); library.appendChild(toolbar);
    var list = S.node("div", "project-library-list"), count = S.node("div", "project-library-count");
    library.appendChild(list); library.appendChild(count);
    var detailHost = S.node("div", "project-library-detail"), empty = S.node("div", "project-library-empty");
    empty.appendChild(S.icon("folder.fill", "project-empty-icon"));
    empty.appendChild(S.node("h2", null, "打开工作文件夹"));
    empty.appendChild(S.node("p", null, "选择项目，查看会话、技能和验证命令。"));
    var emptyAdd = S.button("打开文件夹…", null, {}, null, "primary");
    emptyAdd.addEventListener("click", function () { context.emit("registerProject", {}); });
    empty.appendChild(emptyAdd); detailHost.appendChild(empty);
    root.appendChild(library); root.appendChild(detailHost);
    document.getElementById("projects-content").appendChild(root);
    return { add: add, emptyAdd: emptyAdd, list: list, count: count, detailHost: detailHost, empty: empty };
  }

  function render(page, emit) {
    context.page = page; context.emit = emit;
    if (!shell) shell = createShell();
    shell.add.disabled = shell.emptyAdd.disabled = !page || !page.canRegister;
    if (!page) { details.forEach(function (detail) { detail.setAvailable(false); }); return; }
    renderList();
    var rows = S.safeArray(page.rows), ids = new Set(rows.map(function (row) { return row.projectID; }));
    var selected = rows.find(function (row) { return row.projectID === page.selectedProjectID; });
    shell.empty.hidden = !!selected;
    details.forEach(function (detail, id) {
      if (!ids.has(id)) { detail.root.remove(); details.delete(id); }
      else detail.root.hidden = !selected || id !== selected.projectID;
    });
    if (!selected) return;
    var detail = details.get(selected.projectID);
    if (!detail) {
      detail = createDetail(selected.projectID); details.set(selected.projectID, detail);
      shell.detailHost.appendChild(detail.root);
    }
    detail.root.hidden = false; detail.update(page, selected);
  }

  function renderList() {
    var page = context.page, rows = S.safeArray(page && page.rows), query = context.filter.trim().toLocaleLowerCase();
    var filtered = rows.filter(function (project) {
      return !query || [project.name, project.path, project.projectID].join(" ").toLocaleLowerCase().includes(query);
    });
    shell.count.textContent = rows.length + " 个项目";
    var update = function () {
      S.clear(shell.list);
      filtered.forEach(function (project) {
        var selected = project.projectID === page.selectedProjectID;
        var row = S.node("button", "project-library-row" + (selected ? " selected" : "")); row.type = "button";
        row.setAttribute("aria-current", selected ? "true" : "false");
        row.appendChild(S.icon("folder.fill", "project-library-icon"));
        var copy = S.node("span", "row-main"); copy.appendChild(S.node("span", "row-title", project.name));
        var path = S.node("span", "row-detail", compactPath(project.path || project.detail || project.projectID));
        path.title = project.path || ""; copy.appendChild(path); row.appendChild(copy);
        row.addEventListener("click", function () { context.emit("selectProject", { projectID: project.projectID }); });
        shell.list.appendChild(row);
      });
      if (!filtered.length) shell.list.appendChild(S.node("p", "list-empty", query ? "没有匹配的项目" : "还没有项目"));
    };
    var stable = global.CodexBridgeDesktopStableRender;
    if (stable) stable(shell.list, JSON.stringify([filtered, page && page.selectedProjectID]), update); else update();
  }

  function compactPath(value) {
    var parts = value.split(/[\\/]/).filter(Boolean);
    return parts.length > 2 ? "…/" + parts.slice(-2).join("/") : value;
  }

  function createDetail(projectID) {
    var current = { project: null }, signatures = {}, activeTab = "overview";
    var root = S.node("section", "project-workspace"), header = S.node("header", "project-workspace-heading");
    var copy = S.node("div", "project-workspace-title"), name = S.node("h2"), path = S.node("p", "project-path");
    copy.appendChild(name); copy.appendChild(path); header.appendChild(copy);
    var actions = S.node("div", "project-detail-actions"), start = S.button("新建对话", null, {}, null, "primary small");
    start.addEventListener("click", function () { global.CodexBridgeDesktopDSHWorkbench.openConversation(projectID); });
    actions.appendChild(start);
    var more = S.node("details", "project-maintenance"), remove = S.button("移除项目…", null, {}, null, "small danger");
    more.appendChild(S.node("summary", null, "更多")); more.appendChild(remove);
    more.addEventListener("keydown", function (event) {
      if (event.key !== "Escape" || !more.open) return;
      event.preventDefault(); more.open = false; more.firstChild.focus();
    });
    remove.addEventListener("click", function () {
      if (remove.disabled || !global.confirm("从 Codex Bridge 移除项目“" + current.project.name + "”？\n本地磁盘文件会保留。")) return;
      context.emit("removeProject", { projectID: projectID });
    });
    actions.appendChild(more); header.appendChild(actions); root.appendChild(header);
    var tabBar = S.node("div", "project-tabs"), paneHost = S.node("div", "project-tab-content");
    tabBar.setAttribute("role", "tablist"); tabBar.setAttribute("aria-label", "项目内容");
    var tabs = {}, panes = {}, baseID = "project-view-" + (++detailSequence);
    [ ["overview", "工作区"], ["sessions", "会话"], ["skills", "技能"] ].forEach(function (entry, index, entries) {
      var key = entry[0], tab = S.node("button", "project-tab", entry[1]); tab.type = "button";
      tab.id = baseID + "-tab-" + key; tab.setAttribute("role", "tab"); tab.setAttribute("aria-controls", baseID + "-" + key);
      var pane = S.node("section", "project-tab-pane"); pane.id = baseID + "-" + key;
      pane.setAttribute("role", "tabpanel"); pane.setAttribute("aria-labelledby", tab.id); pane.tabIndex = 0;
      tab.addEventListener("click", function () { selectTab(key); });
      tab.addEventListener("keydown", function (event) {
        var next = -1;
        if (event.key === "ArrowRight") next = (index + 1) % entries.length;
        if (event.key === "ArrowLeft") next = (index + entries.length - 1) % entries.length;
        if (event.key === "Home") next = 0;
        if (event.key === "End") next = entries.length - 1;
        if (next < 0) return;
        event.preventDefault(); selectTab(entries[next][0]); tabs[entries[next][0]].focus();
      });
      tabs[key] = tab; panes[key] = pane; tabBar.appendChild(tab); paneHost.appendChild(pane);
    });
    root.appendChild(tabBar); root.appendChild(paneHost); selectTab(activeTab);
    var info = S.node("dl", "project-workspace-facts"), status = S.node("dd"), description = S.node("p", "project-workspace-description");
    info.appendChild(S.node("dt", null, "Git 状态")); info.appendChild(status);
    panes.overview.appendChild(info); panes.overview.appendChild(description);
    var commands = S.node("div", "project-verification"); panes.overview.appendChild(commands);

    function selectTab(key) {
      activeTab = key;
      Object.keys(tabs).forEach(function (id) {
        var selected = key === id; tabs[id].setAttribute("aria-selected", String(selected));
        tabs[id].tabIndex = selected ? 0 : -1; panes[id].hidden = !selected;
      });
    }
    function updateCollection(key, target, page, value) {
      var signature = JSON.stringify(value);
      if (signature === signatures[key]) return;
      var update = function () {
        S.clear(target); global.CodexBridgeDesktopProjectCollections.render(target, page, context.emit, key);
      };
      if (global.CodexBridgeDesktopStableRender) global.CodexBridgeDesktopStableRender(target, signature, update); else update();
      signatures[key] = signature;
    }
    return {
      root: root,
      setAvailable: function (available) { remove.disabled = start.disabled = !available; },
      update: function (page, project) {
        current.project = project; name.textContent = project.name;
        path.textContent = project.path || ""; path.title = project.path || ""; path.hidden = !project.path;
        var git = S.gitStateBadge(project.gitState);
        status.textContent = git ? git.label : "未检查";
        description.textContent = page.selectedProjectDetail || ""; description.hidden = !page.selectedProjectDetail;
        remove.disabled = !page.canRemove; start.disabled = !page.canRegister;
        tabs.sessions.textContent = "会话 " + S.safeArray(page.sessions).length;
        tabs.skills.textContent = "技能 " + S.safeArray(page.skills).length;
        updateCollection("verification", commands, page, page.verificationCommands);
        updateCollection("sessions", panes.sessions, page, page.sessions);
        updateCollection("skills", panes.skills, page, page.skills);
      }
    };
  }

  global.CodexBridgeDesktopProjectsPage = { render: render };
}(window));
