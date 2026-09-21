(function (global) {
  "use strict";

  var S = global.CodexBridgeDesktopPageSupport;

  function render(page, emit) {
    var container = document.getElementById("logs-content");
    var view = container.__logsPage || (container.__logsPage = create(container, emit));
    view.update(page, emit);
  }

  function create(container, emit) {
    S.clear(container);
    var header = S.node("div");
    var filters = createFilterBar(emit);
    var list = S.node("div", "log-list");
    var detail = S.node("div", "page-message mono");
    var unavailable = S.node("div");
    container.appendChild(header);
    container.appendChild(filters.root);
    container.appendChild(list);
    container.appendChild(detail);
    container.appendChild(unavailable);

    return {
      update: function (page, nextEmit) {
        filters.emit = nextEmit;
        if (!page) {
          S.pageHeader(header, {
            title: "日志",
            subtitle: "正在从本机 Service 读取执行事件。",
            symbol: "list.dash.header.rectangle"
          });
          filters.root.hidden = true;
          list.hidden = true;
          detail.hidden = true;
          unavailable.hidden = false;
          S.empty(unavailable, "日志页暂不可用", "连接本机 Service 后，任务事件会显示在这里。");
          return;
        }
        S.pageHeader(header, page.header);
        filters.root.hidden = false;
        list.hidden = false;
        detail.hidden = !page.detailText;
        unavailable.hidden = true;
        filters.update(page, nextEmit);
        var signature = JSON.stringify([page.rows, page.selectedRowID, page.searchText]);
        var renderList = function () {
          S.clear(list);
          S.safeArray(page.rows).forEach(function (row) {
            list.appendChild(logRow(row, page, filters.emit));
          });
          if (!page.rows || page.rows.length === 0) {
            list.appendChild(S.node(
              "div",
              "empty-state",
              page.searchText ? "没有匹配的日志事件。" : "暂无日志事件。"
            ));
          }
        };
        var stable = global.CodexBridgeDesktopStableRender;
        if (stable) stable(list, signature, renderList); else renderList();
        detail.textContent = page.detailText || "";
      }
    };
  }

  function createFilterBar(emit) {
    var context = { emit: emit };
    var bar = S.node("div", "filter-bar");
    var search = S.node("input", "search-field");
    search.type = "search";
    search.placeholder = "搜索日志摘要、命令或文件…";
    var searchDirty = false;
    var searchTimer = null;
    search.addEventListener("input", function () {
      searchDirty = true;
      global.clearTimeout(searchTimer);
      searchTimer = global.setTimeout(function () {
        context.emit("setLogSearch", { searchText: search.value });
      }, 180);
    });
    bar.appendChild(search);

    var project = S.selectField("项目", "all", [], function (value) {
      context.emit("setLogProjectFilter", { projectID: value === "all" ? null : value });
    }, "");
    bar.appendChild(project.wrapper);
    var kind = S.selectField("类型", "all", [], function (value) {
      context.emit("setLogKindFilter", { kind: value });
    }, "");
    bar.appendChild(kind.wrapper);

    var copy = S.button("复制日志", null, {}, null, "small", true);
    copy.addEventListener("click", function () {
      context.emit("copyLogs", {});
      copy.textContent = "已复制";
      copy.__copied = true;
      global.setTimeout(function () {
        copy.__copied = false;
        copy.textContent = "复制日志";
      }, 1500);
    });
    bar.appendChild(copy);
    var refresh = S.button("刷新", null, {}, null, "small primary", true);
    refresh.addEventListener("click", function () { context.emit("refreshLogs", {}); });
    bar.appendChild(refresh);

    function update(page, nextEmit) {
      if (nextEmit) context.emit = nextEmit;
      if (searchDirty && search.value === (page.searchText || "")) searchDirty = false;
      if (!searchDirty && document.activeElement !== search) search.value = page.searchText || "";
      setOptions(project.control, page.projectOptions, page.selectedProjectID || "all", [
        { id: "all", title: "全部项目" }
      ]);
      setOptions(kind.control, page.kindOptions, page.selectedKind || "all", [
        { id: "all", title: "全部" }
      ]);
      copy.disabled = !page.canCopy;
      refresh.disabled = !page.canRefresh;
    }

    return { root: bar, emit: context.emit, update: update };
  }

  function setOptions(control, choices, value, fallback) {
    var options = choices && choices.length ? choices : fallback;
    var signature = JSON.stringify(options);
    if (control.__choiceSignature !== signature) {
      control.__choiceSignature = signature;
      S.clear(control);
      options.forEach(function (choice) {
        var option = S.node("option", null, choice.title);
        option.value = choice.id;
        option.disabled = choice.enabled === false;
        option.title = choice.detail || "";
        control.appendChild(option);
      });
    }
    control.value = value;
  }

  function logRow(row, page, emit) {
    var element = S.node("button", "log-row" + (row.id === page.selectedRowID ? " selected" : ""));
    element.type = "button";
    element.appendChild(S.node("span", "mono muted", "#" + row.sequence));
    element.appendChild(S.node("span", "row-detail", row.projectName));
    element.appendChild(S.badge(row.kindLabel || row.kind, row.kindLabel === "错误" ? "error" : "neutral"));
    element.appendChild(S.node("span", "log-summary mono", row.summary));
    element.appendChild(S.node("span", "log-time mono muted", row.timestamp));
    element.addEventListener("click", function () {
      emit("selectLog", { logID: row.id, taskID: row.taskID });
    });
    return element;
  }

  global.CodexBridgeDesktopLogsPage = { render: render };
}(window));
