(function (global) {
  "use strict";
  var S = global.CodexBridgeDesktopPageSupport;
  var statuses = [
    ["", "全部状态"], ["completed", "已完成"], ["failed", "失败"],
    ["interrupted", "已中断"], ["running", "运行中"], ["starting", "正在启动"],
    ["queued", "排队中"], ["awaiting_local_approval", "等待启动审批"],
    ["waiting_for_codex_approval", "等待执行审批"], ["unknown", "状态未知"]
  ];

  function setOptions(select, choices) {
    var signature = JSON.stringify(choices);
    if (select.__options === signature) return;
    select.__options = signature;
    var value = select.value;
    S.clear(select);
    choices.forEach(function (choice) {
      var option = S.node("option", null, choice[1]);
      option.value = choice[0]; select.appendChild(option);
    });
    select.value = value;
  }

  function create(parent) {
    var model = { page: null, emit: null };
    var panel = S.node("details", "workbench-history-search");
    model.panel = panel;
    panel.appendChild(S.node("summary", null, "搜索历史会话"));
    var form = S.node("form", "history-search-form");
    model.input = S.node("input"); model.input.type = "search";
    model.input.placeholder = "搜索标题或原始要求";
    model.input.setAttribute("aria-label", "历史会话关键词");
    model.input.maxLength = 1024;
    model.provider = S.node("select"); model.provider.setAttribute("aria-label", "历史会话 Agent");
    model.status = S.node("select"); model.status.setAttribute("aria-label", "历史会话状态");
    setOptions(model.status, statuses);
    model.search = S.node("button", "small", "搜索"); model.search.type = "submit";
    form.appendChild(model.input); form.appendChild(model.provider); form.appendChild(model.status);
    form.appendChild(model.search);
    model.clear = S.node("button", "small", "清除"); model.clear.type = "button";
    model.clear.addEventListener("click", function () {
      model.input.value = model.provider.value = model.status.value = "";
      if (model.emit) model.emit("searchTaskHistory", { action: "clear" });
    });
    form.appendChild(model.clear);
    form.addEventListener("submit", function (event) {
      event.preventDefault();
      if (model.emit) model.emit("searchTaskHistory", {
        input: model.input.value, providerID: model.provider.value, mode: model.status.value, offset: 0
      });
    });
    panel.appendChild(form);
    model.note = S.node("div", "muted history-search-note");
    model.note.setAttribute("role", "status");
    model.note.setAttribute("aria-live", "polite"); panel.appendChild(model.note);
    model.results = S.node("div", "history-search-results"); panel.appendChild(model.results);
    model.more = S.node("button", "small", "加载更多"); model.more.type = "button";
    model.more.addEventListener("click", function () {
      var state = model.page && model.page.taskHistorySearch || {};
      if (model.emit && !state.isLoading) model.emit("searchTaskHistory", { offset: state.nextOffset });
    });
    panel.appendChild(model.more); parent.appendChild(panel);
    return model;
  }

  function update(model, page, emit) {
    model.page = page; model.emit = emit;
    var state = page.taskHistorySearch || {};
    setOptions(model.provider, [["", "全部 Agent"]].concat(S.safeArray(state.providers).map(function (item) {
      return [item.id, item.title];
    })));
    var querySignature = JSON.stringify([page.selectedProjectID, state.search, state.providerID, state.status]);
    if (model.__query !== querySignature) {
      model.__query = querySignature;
      model.input.value = state.search || "";
      model.provider.value = state.providerID || "";
      model.status.value = state.status || "";
    }
    var results = S.safeArray(state.results);
    model.panel.setAttribute("aria-busy", String(!!state.isLoading));
    model.search.disabled = !page.selectedProjectID;
    model.more.hidden = !state.canLoadMore;
    model.more.disabled = !!state.isLoading;
    model.note.className = state.errorMessage ? "error-text history-search-note" : "muted history-search-note";
    model.note.textContent = state.errorMessage || (state.isLoading ? "正在查询历史会话…"
      : !state.hasSearched ? "在当前项目的全部历史记录中搜索。"
      : results.length ? "找到 " + results.length + " 条记录" + (state.canLoadMore ? "，可继续加载。" : "。")
      : "没有符合条件的历史会话。");
    var signature = JSON.stringify([results, page.selectedTaskID]);
    if (model.__results === signature) return;
    model.__results = signature; S.clear(model.results);
    results.forEach(function (result) {
      var button = S.button("", "selectTaskHistory", { taskID: result.taskID }, emit, "history-search-result");
      button.classList.toggle("is-selected", result.taskID === page.selectedTaskID);
      button.appendChild(S.node("span", "history-search-title", result.title));
      button.appendChild(S.node("span", "muted", result.provider + " · " + result.status + " · "
        + new Date(result.updatedAt).toLocaleString()));
      model.results.appendChild(button);
    });
  }

  global.CodexBridgeDesktopTaskHistorySearch = { create: create, update: update };
}(window));
