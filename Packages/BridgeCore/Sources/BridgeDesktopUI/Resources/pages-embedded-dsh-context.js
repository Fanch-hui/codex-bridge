(function (global) {
  "use strict";
  var S = global.CodexBridgeDesktopPageSupport;
  var T = global.CodexBridgeDesktopEmbeddedDSHTransport;

  function create(options) {
    var isSession = options.scope === "session", sessionID = null, active = false;
    var root = S.node("div", "dsh-context-editor"), state = null;
    var revision = 0, request = 0, busy = false, dirty = false, stale = true, refreshPending = false;
    var source = S.node("p", "hint dsh-context-source"), limit = S.node("p", "hint dsh-context-limit");
    var contextWindow = S.textField("上下文窗口（tokens）", "", ""), threshold = S.textField("自动压缩阈值（tokens）", "", "");
    var actions = S.node("div", "form-actions"), feedback = S.node("p", "hint dsh-context-feedback");
    var save = S.button("保存", null, null, null, "small"), reset = S.button(isSession ? "跟随全局" : "恢复默认", null, null, null, "small");
    var retry = S.button("重试", null, null, null, "small");
    feedback.setAttribute("role", "status");
    [contextWindow, threshold].forEach(function (field) {
      field.control.inputMode = "numeric";
      field.control.addEventListener("input", function () { dirty = true; showFeedback(""); syncControls(); });
    });
    if (!isSession) root.appendChild(S.node("p", "hint", "应用于所有工作台会话和模型，从下一执行步骤生效。"));
    if (isSession) root.appendChild(source);
    root.appendChild(limit); root.appendChild(contextWindow.wrapper); root.appendChild(threshold.wrapper);
    actions.appendChild(save); actions.appendChild(reset); actions.appendChild(retry);
    root.appendChild(actions); root.appendChild(feedback);
    save.addEventListener("click", function () {
      var policy;
      try { policy = readInputs(); } catch (error) { showFeedback(error.message); return; }
      void setPolicy(policy);
    });
    reset.addEventListener("click", function () { void setPolicy(null); });
    retry.addEventListener("click", function () { void refresh(); });
    syncControls();

    function readInputs() {
      var windowText = contextWindow.control.value.trim(), thresholdText = threshold.control.value.trim();
      var windowValue = Number(windowText), thresholdValue = Number(thresholdText);
      if (!/^\d+$/.test(windowText) || !Number.isSafeInteger(windowValue) || windowValue < 4096 || windowValue > 10000000) {
        throw new Error("上下文窗口需为 4,096 到 10,000,000 之间的整数。");
      }
      if (!/^\d+$/.test(thresholdText) || !Number.isSafeInteger(thresholdValue) || thresholdValue < 1024 || thresholdValue >= windowValue) {
        throw new Error("自动压缩阈值需至少为 1,024，且小于上下文窗口。");
      }
      return { contextWindow: windowValue, autoCompactAt: thresholdValue };
    }
    function showFeedback(message) {
      feedback.textContent = message; feedback.hidden = !message;
    }
    function syncControls() {
      var enabled = !!state && !busy && (!isSession || !!sessionID);
      contextWindow.control.disabled = threshold.control.disabled = !enabled;
      save.disabled = !enabled || !dirty;
      reset.disabled = !enabled || (isSession && state.source !== "session" && !dirty);
      retry.hidden = !!state || !feedback.textContent || busy;
      retry.disabled = busy;
    }
    function display(result, force) {
      state = result; stale = false;
      var selected = isSession && result.override || result.defaults;
      if (selected && (!dirty || force)) {
        contextWindow.control.value = String(selected.contextWindow);
        threshold.control.value = String(selected.autoCompactAt);
      }
      source.textContent = result.source === "session" ? "本次会话" : "跟随全局设置";
      var effective = result.effective || {};
      limit.textContent = result.limitedByModel && effective.contextWindow && effective.autoCompactAt
        ? "受模型容量限制，实际窗口 " + effective.contextWindow.toLocaleString() + "，压缩阈值 " + effective.autoCompactAt.toLocaleString() + " tokens。" : "";
      limit.hidden = !limit.textContent;
      if (typeof options.onPolicy === "function") options.onPolicy(result);
      syncControls();
    }
    function payload(policy) {
      var input = isSession ? { sessionId: sessionID } : {};
      if (arguments.length) input.policy = policy;
      return input;
    }
    function refresh() {
      if (isSession && !sessionID) return Promise.resolve();
      if (busy) { refreshPending = true; return Promise.resolve(); }
      var current = revision, id = ++request;
      return T.call("context.get", payload()).then(function (result) {
        if (current !== revision || id !== request) return;
        display(result, false); if (!dirty) showFeedback("");
      }).catch(function (error) {
        if (current !== revision || id !== request) return;
        stale = true; showFeedback(error && error.message || "读取上下文设置失败，请重试。"); syncControls();
      });
    }
    function setPolicy(policy) {
      if (busy || !state || isSession && !sessionID) return Promise.resolve();
      var current = revision;
      ++request; busy = true; refreshPending = false; showFeedback(""); syncControls();
      return T.call("context.set", payload(policy)).then(function (result) {
        if (current !== revision) return;
        dirty = false; display(result, true); showFeedback("已保存。");
      }).catch(function (error) {
        if (current !== revision) return;
        showFeedback(error && error.message || "保存失败，请重试。");
      }).finally(function () {
        if (current !== revision) return;
        busy = false; syncControls();
        if (refreshPending) { refreshPending = false; void refresh(); }
      });
    }
    function setSession(id) {
      if (!isSession || sessionID === id) return;
      sessionID = id || null; revision++; request++; busy = false; dirty = false; stale = true; refreshPending = false;
      state = null; contextWindow.control.value = threshold.control.value = ""; source.textContent = "";
      limit.hidden = true; showFeedback(""); syncControls();
      if (active && sessionID) void refresh();
    }
    function setActive(value) {
      var opening = !!value && !active;
      active = !!value;
      if (active && (opening || stale) && (!isSession || sessionID)) void refresh();
    }
    function receive(item) {
      if (!item || item.type !== "context.changed") return;
      if (!isSession && item.sessionID) return;
      if (isSession && item.sessionID && item.sessionID !== sessionID) return;
      stale = true;
      if (active || state) void refresh();
    }
    return { root: root, setSession: setSession, setActive: setActive, receive: receive, refresh: refresh };
  }
  global.CodexBridgeDesktopEmbeddedDSHContext = { create: create };
}(window));
