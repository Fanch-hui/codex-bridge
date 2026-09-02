(function (global) {
  "use strict";

  var S = global.CodexBridgeDesktopPageSupport;

  function render(page, emit) {
    var container = document.getElementById("logs-content");
    S.clear(container);
    if (!page) {
      var unavailableHeader = S.node("div");
      S.pageHeader(unavailableHeader, { title: "日志", subtitle: "正在从本机 Service 读取执行事件。", symbol: "list.dash.header.rectangle" });
      container.appendChild(unavailableHeader);
      var unavailable = S.node("div");
      S.empty(unavailable, "日志页暂不可用", "连接本机 Service 后，任务事件会显示在这里。");
      container.appendChild(unavailable);
      return;
    }
    var header = S.node("div");
    S.pageHeader(header, page.header);
    container.appendChild(header);
    container.appendChild(filterBar(page, emit));
    var list = S.node("div", "log-list");
    S.safeArray(page.rows).forEach(function (row) { list.appendChild(logRow(row, page, emit)); });
    if (!page.rows || page.rows.length === 0) list.appendChild(S.node("div", "empty-state", page.searchText ? "没有匹配的日志事件。" : "暂无日志事件。"));
    container.appendChild(list);
    if (page.detailText) container.appendChild(S.node("div", "page-message mono", page.detailText));
  }

  function filterBar(page, emit) {
    var bar = S.node("div", "filter-bar");
    var search = S.node("input", "search-field");
    search.type = "search";
    search.value = page.searchText || "";
    search.placeholder = "搜索日志摘要、命令或文件…";
    var searchTimer = null;
    search.addEventListener("input", function () {
      global.clearTimeout(searchTimer);
      searchTimer = global.setTimeout(function () {
        emit("setLogSearch", { searchText: search.value });
      }, 180);
    });
    bar.appendChild(search);
    var projects = page.projectOptions && page.projectOptions.length ? page.projectOptions : [{ id: "all", title: "全部项目" }];
    var project = S.selectField("项目", page.selectedProjectID || "all", projects, function (value) {
      emit("setLogProjectFilter", { projectID: value === "all" ? null : value });
    }, "");
    bar.appendChild(project.control);
    var kinds = page.kindOptions && page.kindOptions.length ? page.kindOptions : [{ id: "all", title: "全部" }];
    var kind = S.selectField("类型", page.selectedKind || "all", kinds, function (value) {
      emit("setLogKindFilter", { kind: value });
    }, "");
    bar.appendChild(kind.control);
    var copy = S.button("复制日志", null, {}, emit, "small", !page.canCopy);
    copy.addEventListener("click", function () {
      emit("copyLogs", {});
      copy.textContent = "已复制";
      global.setTimeout(function () { copy.textContent = "复制日志"; }, 1500);
    });
    bar.appendChild(copy);
    bar.appendChild(S.button("刷新", "refreshLogs", {}, emit, "small primary", !page.canRefresh));
    return bar;
  }

  function logRow(row, page, emit) {
    var element = S.node("button", "log-row" + (row.id === page.selectedRowID ? " selected" : ""));
    element.type = "button";
    element.appendChild(S.node("span", "mono muted", "#" + row.sequence));
    element.appendChild(S.node("span", "row-detail", row.projectName));
    element.appendChild(S.badge(row.kindLabel || row.kind, row.kindLabel === "错误" ? "error" : "neutral"));
    element.appendChild(S.node("span", "log-summary mono", row.summary));
    element.appendChild(S.node("span", "log-time mono muted", row.timestamp));
    element.addEventListener("click", function () { emit("selectLog", { logID: row.id, taskID: row.taskID }); });
    return element;
  }

  global.CodexBridgeDesktopLogsPage = { render: render };
}(window));
