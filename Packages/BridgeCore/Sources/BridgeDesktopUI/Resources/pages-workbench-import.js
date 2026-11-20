(function (global) {
  "use strict";
  var S = global.CodexBridgeDesktopPageSupport, T = global.CodexBridgeDesktopEmbeddedDSHTransport;
  var O = global.CodexBridgeDesktopEmbeddedDSHOperations;
  var states = new Map(), jobs = O.create(), inFlight = new Set(), visible = false, intent = null;
  var recovery = O.createRecovery({ jobs: jobs, inFlight: inFlight, transport: T,
    isReady: function () { return visible; },
    onAccepted: accepted, onFailed: failed,
    onReconciling: function (job) { state(job.taskID).message = "正在核对转入结果…"; repaint(); },
    onUpdate: repaint });
  var current = null;

  function state(taskID) {
    if (!states.has(taskID)) states.set(taskID, { taskID: taskID, message: "", busy: false, sessionID: null });
    return states.get(taskID);
  }
  function decoded(operation) {
    return operation && operation.resultJSON ? JSON.parse(operation.resultJSON) : {};
  }
  function open(sessionID) {
    global.dispatchEvent(new CustomEvent("codex-bridge-open-workbench-session", { detail: { sessionID: sessionID } }));
  }
  function accepted(job, operation) {
    var value = state(job.taskID);
    try {
      var result = decoded(operation);
      if (!result.sessionID) throw new Error("未收到工作台会话，请重新核对。");
      value.sessionID = result.sessionID; value.message = "已带到工作台。";
      value.busy = false; jobs.remove(job); inFlight.delete(job.requestId); repaint();
      if (visible && intent === job.taskID) { intent = null; open(result.sessionID); }
    } catch (error) {
      value.busy = false; value.message = error.message; repaint();
    }
  }
  function failed(job, operation) {
    var value = state(job.taskID), result = decoded(operation);
    value.busy = false; value.message = result.message || "转入未完成，请重试。";
    jobs.remove(job); inFlight.delete(job.requestId); repaint();
  }
  function repaint() {
    if (!current) return;
    var value = state(current.taskID);
    current.button.disabled = value.busy;
    current.button.textContent = value.busy ? "正在带到工作台…" : value.sessionID ? "打开工作台会话" : "带到工作台";
    current.feedback.textContent = value.message;
    current.feedback.hidden = !value.message;
  }
  function transfer(taskID) {
    var value = state(taskID);
    if (value.busy) return;
    intent = taskID;
    if (value.sessionID) { open(value.sessionID); return; }
    var requestId = "workbench.importTask:" + taskID;
    var job = { taskID: taskID, requestId: requestId };
    jobs.add(job); value.busy = true; value.message = ""; inFlight.add(requestId); repaint();
    return T.call("operations.submit", { operationID: requestId, requestID: requestId,
      kind: "workbench.importTask", input: { taskID: taskID } }).then(function (result) {
      if (!recovery.inspect(job, result)) recovery.schedule(job, 0);
    }).catch(function (error) {
      if (error.code === "workbench_disabled") {
        jobs.remove(job); inFlight.delete(requestId); value.busy = false; value.message = "请先在设置中开启工作台。"; repaint();
      } else if (error.code && !["service_unavailable", "embedded_dsh_transport_timeout", "embedded_dsh_runtime"].includes(error.code)) {
        jobs.remove(job); inFlight.delete(requestId); value.busy = false; value.message = error.message || "无法带到工作台。"; repaint();
      } else recovery.schedule(job, 0);
    });
  }
  function attach(host, detail) {
    host.hidden = !detail;
    if (!detail) { current = null; intent = null; return; }
    if (!host.__importControl) {
      var button = S.button("带到工作台", null, {}, null, "small"), feedback = S.node("span", "workbench-import-feedback");
      feedback.setAttribute("role", "status");
      var control = { button: button, feedback: feedback, taskID: null };
      button.addEventListener("click", function () { transfer(control.taskID); });
      host.appendChild(button); host.appendChild(feedback); host.__importControl = control;
    }
    var control = host.__importControl;
    if (control.taskID !== detail.taskID) intent = null;
    control.taskID = detail.taskID; current = control; repaint();
  }
  function setActive(active) {
    visible = !!active;
    if (!visible) { intent = null; recovery.clearTimers(); return; }
    jobs.list().forEach(function (job) { recovery.schedule(job, 0); });
  }
  function renderSource(entry, node) {
    if (!node) {
      node = S.node("details", "workbench-source-card");
      var title = S.node("summary"), text = S.node("pre"), link = S.button("查看原网页任务", null, {}, null, "small");
      node.appendChild(title); node.appendChild(text); node.appendChild(link);
      node.__sourceCard = { title: title, text: text, link: link, entry: entry };
      link.addEventListener("click", function () { global.CodexBridgeDesktopDSHWorkbench.openTask(node.__sourceCard.entry.taskID); });
    }
    var card = node.__sourceCard; card.entry = entry;
    if (card.title.textContent !== entry.title) card.title.textContent = entry.title;
    if (card.text.textContent !== entry.text) card.text.textContent = entry.text;
    return node;
  }
  global.CodexBridgeDesktopWorkbenchImport = { attach: attach, setActive: setActive, renderSource: renderSource };
}(window));
