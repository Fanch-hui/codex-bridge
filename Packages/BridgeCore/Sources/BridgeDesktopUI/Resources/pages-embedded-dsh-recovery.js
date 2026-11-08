(function (global) {
  "use strict";
  var S = global.CodexBridgeDesktopPageSupport, T = global.CodexBridgeDesktopEmbeddedDSHTransport;

  function create(container, openSession) {
    var root = S.node("section", "dsh-embedded-recovery"), projectID = null, sessionID = null;
    var active = false, revision = 0, timer = null, inFlight = false, items = [], failure = "", pending = new Map(), operationSequence = 0;
    var presentation = "";
    var validation = global.CodexBridgeDesktopEmbeddedDSHValidation.create(container, function () { refresh(); });
    root.setAttribute("aria-label", "项目恢复");

    function stopTimer() { if (timer) global.clearTimeout(timer); timer = null; }
    function schedule() {
      stopTimer();
      if (!active || !projectID) return;
      timer = global.setTimeout(function () { timer = null; refresh(); }, items.length ? 5000 : 15000);
      if (timer && timer.unref) timer.unref();
    }
    function setContext(nextProject, nextSession, enabled) {
      nextProject = nextProject || null; nextSession = nextSession || null; enabled = !!enabled;
      if (projectID === nextProject && sessionID === nextSession && active === enabled) return;
      var projectChanged = projectID !== nextProject;
      projectID = nextProject; sessionID = nextSession; active = enabled; revision++;
      validation.setContext(projectID, active);
      stopTimer();
      if (projectChanged || !active) { items = []; failure = ""; pending.clear(); render(); }
      if (active && projectID) refresh();
    }
    function refresh() {
      if (!active || !projectID || inFlight) return Promise.resolve();
      var project = projectID, request = revision;
      inFlight = true;
      return T.read("workspace.recovery:" + project, function () {
        return T.call("workspace.recovery.list", { projectID: project });
      }).then(function (value) {
        if (!active || project !== projectID || request !== revision) return;
        items = S.safeArray(value && value.items); failure = ""; render();
      }).catch(function (error) {
        if (!active || project !== projectID || request !== revision) return;
        failure = error && error.message || "无法读取项目恢复状态。"; render();
      }).finally(function () {
        inFlight = false;
        if (request !== revision && active && projectID) refresh();
        else schedule();
      });
    }
    function button(title, action, disabled, key) {
      var value = S.button(title, null, {}, null, "small");
      if (key) value.dataset.recoveryFocus = key;
      value.disabled = !!disabled; value.addEventListener("click", action); return value;
    }
    function perform(item, action) {
      if (!item.recoveryID || pending.has(item.recoveryID)) return;
      if (action === "confirmLegacy" && !global.confirm("请先确认该会话遗留的所有后台进程均已结束。确认后将解除项目写入占用，继续吗？")) return;
      if (action === "rollback" && !global.confirm("将按恢复记录撤回未完成的合并，继续吗？")) return;
      var project = projectID, request = revision, id = item.recoveryID;
      var input = { projectID: project, recoveryID: id };
      if (item.sessionId) input.sessionId = item.sessionId;
      if (action === "confirmLegacy") input.confirmed = true;
      var operation = ++operationSequence;
      pending.set(id, operation); failure = ""; render();
      var succeeded = false;
      T.call("workspace.recovery." + action, input).then(function (value) {
        if (request !== revision || project !== projectID) return;
        succeeded = true;
        if (action === "resume" && value && value.sessionId && openSession) openSession(value.sessionId);
      }).catch(function (error) {
        if (request !== revision || project !== projectID) return;
        failure = error && error.code === "embedded_dsh_transport_timeout"
          ? "正在核对恢复状态。" : error && error.message || "恢复操作失败，请重试。";
      }).finally(function () {
        if (pending.get(id) === operation) pending.delete(id);
        if (project === projectID) {
          render();
          if (succeeded || request !== revision) refresh(); else schedule();
        }
      });
    }
    function status(item) {
      var states = { running: "后台进程仍在运行", exited: "后台进程已结束", unknown: "等待核对进程",
        checking: "正在核对", recovering: "正在恢复", recovery_required: "合并等待恢复", blocked: "项目写入已暂停",
        validating: "正在验证候选版本", validation_required: "请配置验证命令后继续合并" };
      if (item.kind === "legacy" && !item.message) return "没有可核对的进程身份。确认相关后台程序已结束后，可解除占用。";
      return item.message || states[item.status] || "项目写入等待恢复";
    }
    function renderItem(item) {
      var card = S.node("section", "dsh-embedded-request");
      card.appendChild(S.node("strong", null, item.kind === "merge" ? "合并需要恢复" : "工作区需要恢复"));
      var state = S.node("p", "hint", status(item)); state.setAttribute("role", "status"); card.appendChild(state);
      var session = item.sessionTitle || item.sessionId;
      if (session) card.appendChild(S.node("p", "hint", "会话：" + session));
      if (item.candidatePath) card.appendChild(S.node("p", "hint", "候选目录：" + item.candidatePath));
      var processes = S.safeArray(item.processes).filter(function (process) { return Number.isInteger(process.pid) && process.pid > 0; });
      if (processes.length) card.appendChild(S.node("p", "hint", "进程：" + processes.map(function (process) {
        return (process.label ? process.label + " " : "") + process.pid;
      }).join("、")));
      var actions = S.node("div", "form-actions"), busy = pending.has(item.recoveryID);
      if (item.canCheck) actions.appendChild(button("检查状态", function () { perform(item, "check"); }, busy, item.recoveryID + ":check"));
      if (item.canTerminate) actions.appendChild(button("结束进程", function () { perform(item, "terminate"); }, busy, item.recoveryID + ":terminate"));
      if (item.canResume && item.status !== "validation_required") actions.appendChild(button(item.kind === "merge" ? "恢复合并" : "恢复任务", function () { perform(item, "resume"); }, busy, item.recoveryID + ":resume"));
      if (item.canRollback) actions.appendChild(button("撤回合并", function () { perform(item, "rollback"); }, busy, item.recoveryID + ":rollback"));
      if (item.canConfigureValidation) actions.appendChild(button("配置验证命令", function () { validation.open(projectID, item); }, busy, item.recoveryID + ":validation"));
      if (item.canConfirmLegacy) actions.appendChild(button("已核对，解除占用", function () { perform(item, "confirmLegacy"); }, busy, item.recoveryID + ":confirmLegacy"));
      if (busy) actions.appendChild(S.node("span", "hint", "正在处理…"));
      if (actions.children.length) card.appendChild(actions);
      return card;
    }
    function render() {
      var nextPresentation = JSON.stringify([items, failure, Array.from(pending)]);
      if (presentation === nextPresentation) return;
      presentation = nextPresentation;
      var focus = root.contains(document.activeElement) && document.activeElement.dataset.recoveryFocus;
      root.replaceChildren();
      items.forEach(function (item) { if (item && item.recoveryID) root.appendChild(renderItem(item)); });
      if (failure) {
        var message = S.node("p", "hint", failure); message.setAttribute("role", "status"); root.appendChild(message);
        root.appendChild(button("重新检查", refresh));
      }
      if (root.children.length) { if (!root.parentNode) container.appendChild(root); }
      else root.remove();
      if (focus) {
        var replacement = Array.from(root.querySelectorAll("button")).find(function (item) {
          return item.dataset.recoveryFocus === focus && !item.disabled;
        });
        if (replacement) replacement.focus();
      }
    }
    function reveal() {
      return refresh().then(function () {
        if (!root.parentNode) return;
        if (root.scrollIntoView) root.scrollIntoView({ block: "nearest" });
        var first = root.querySelector("button"); if (first && !first.disabled) first.focus();
      });
    }
    return { setContext: setContext, refresh: refresh, reveal: reveal };
  }
  global.CodexBridgeDesktopEmbeddedDSHRecovery = { create: create };
}(window));
