(function (global) {
  "use strict";
  var S = global.CodexBridgeDesktopPageSupport;
  var statusNames = { pending: "待处理", in_progress: "进行中", completed: "已完成" };
  var glyphs = { pending: "circle", in_progress: "circle.fill", completed: "checkmark.circle.fill" };

  function summary(tasks) {
    var counts = { pending: 0, in_progress: 0, completed: 0 };
    tasks.forEach(function (task) { counts[task.status]++; });
    return { text: counts.completed + "/" + tasks.length,
      title: ["已完成 " + counts.completed, "进行中 " + counts.in_progress, "待处理 " + counts.pending].join(" · ") };
  }

  function field(list, name, value) {
    if (!value || Array.isArray(value) && !value.length) return;
    var term = S.node("dt", null, name), detail = S.node("dd");
    if (Array.isArray(value)) value.forEach(function (item) { detail.appendChild(item); });
    else detail.textContent = value;
    list.appendChild(term); list.appendChild(detail);
  }

  function dependency(item) {
    var node = S.node("span", "dsh-team-dependency" + (item.done ? " is-done" : ""), item.title);
    node.title = item.id;
    return node;
  }

  function details(task) {
    var panel = S.node("div", "dsh-team-details"), list = S.node("dl", "dsh-team-fields");
    if (task.description) panel.appendChild(S.node("p", "dsh-team-description", task.description));
    field(list, "负责人", task.ownerName || task.ownerID || "未分配");
    field(list, "依赖", task.dependencies.map(dependency));
    field(list, "写入范围", task.writeScopes.join("、"));
    panel.appendChild(list);
    return panel;
  }

  function row(task, expanded, toggle) {
    var item = S.node("li", "dsh-team-task");
    item.dataset.status = task.status; item.dataset.blocked = String(task.blocked);
    var button = S.button("", null, {}, null, "dsh-team-task-row");
    button.dataset.taskId = task.id; button.setAttribute("aria-expanded", String(expanded));
    button.title = task.subject;
    var glyph = S.node("span", "dsh-team-glyph");
    glyph.setAttribute("role", "img"); glyph.setAttribute("aria-label", task.blocked ? "等待依赖" : statusNames[task.status]);
    glyph.appendChild(S.icon(task.blocked ? "clock" : glyphs[task.status]));
    button.appendChild(glyph); button.appendChild(S.node("span", "dsh-team-subject", task.subject || task.id));
    if (task.ownerName) button.appendChild(S.node("span", "dsh-team-owner", task.ownerName));
    button.addEventListener("click", toggle);
    item.appendChild(button);
    if (expanded) item.appendChild(details(task));
    return item;
  }

  // The shared task list of a session with team mode on; empty or switched-off teams show nothing.
  function create() {
    var root = S.node("section", "dsh-team-board"), expandedID = null, signature = "";
    root.setAttribute("aria-label", "团队任务"); root.hidden = true;
    var header = S.node("header", "dsh-team-header"), title = S.node("h3", null, "团队任务");
    var progress = S.node("span", "dsh-team-progress");
    var failure = S.node("p", "hint dsh-team-failure"); failure.setAttribute("role", "alert"); failure.hidden = true;
    var list = S.node("ul", "dsh-team-tasks");
    header.appendChild(title); header.appendChild(progress);
    root.appendChild(header); root.appendChild(failure); root.appendChild(list);

    function focusedTask() {
      var active = typeof document !== "undefined" && document.activeElement;
      return active && list.contains(active) && active.dataset ? active.dataset.taskId : null;
    }
    function render(state) {
      var restore = focusedTask(), counts = summary(state.tasks);
      S.clear(list);
      state.tasks.forEach(function (task) {
        list.appendChild(row(task, task.id === expandedID, function () {
          expandedID = expandedID === task.id ? null : task.id;
          render(state);
        }));
      });
      progress.textContent = state.tasks.length ? counts.text : ""; progress.title = counts.title;
      failure.textContent = state.failure ? "任务记录无效：" + state.failure : ""; failure.hidden = !state.failure;
      if (restore) {
        var target = Array.from(list.querySelectorAll("button")).find(function (item) { return item.dataset.taskId === restore; });
        if (target) target.focus({ preventScroll: true });
      }
    }
    function update(state) {
      var shown = !!state && state.enabled && (state.tasks.length > 0 || !!state.failure);
      root.hidden = !shown;
      if (!shown) { expandedID = null; signature = ""; return; }
      var next = JSON.stringify(state);
      if (next === signature) return;
      signature = next; render(state);
    }
    return { root: root, update: update };
  }

  var api = { create: create };
  global.CodexBridgeDesktopEmbeddedDSHTeamBoard = api;
}(window));
