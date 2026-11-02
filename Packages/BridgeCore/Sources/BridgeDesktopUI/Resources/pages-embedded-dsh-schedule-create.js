(function (global) {
  "use strict";
  var S = global.CodexBridgeDesktopPageSupport;
  var timingEditor = global.CodexBridgeDesktopEmbeddedDSHSchedules.timingEditor;
  var storageKey = "codexbridge.workbench.scheduleCreateDrafts.v1";
  var delays = [1000, 2000, 4000, 8000, 15000, 30000, 60000];

  function statusAction(value, resent) {
    if (value && value.state === "accepted") return "accepted";
    if (value && value.state === "notFound") return resent ? "failed" : "retry";
    return "wait";
  }
  function defaults(kind) {
    var now = new Date(), zone = Intl.DateTimeFormat().resolvedOptions().timeZone || "UTC";
    if (kind === "at") return { kind: kind, scheduledAt: new Date(now.getTime() + 3600000).toISOString() };
    if (kind === "every") return { kind: kind, everySeconds: 3600 };
    if (kind === "daily") return { kind: kind, time: "09:00", timeZone: zone };
    if (kind === "weekly") return { kind: kind, time: "09:00", timeZone: zone, weekdays: [now.getDay() || 7] };
    return { kind: "cron", expression: "0 9 * * *", timeZone: zone };
  }
  function load() {
    try {
      var value = JSON.parse(global.localStorage.getItem(storageKey) || "{}");
      return value && typeof value === "object" && !Array.isArray(value) ? value : {};
    } catch (_) { return {}; }
  }
  function create(options) {
    var T = options.transport, context = options.getContext(), drafts = load();
    var active = false, expanded = false, current = null, timing = null, retryTimer = null, previewTimer = null;
    var retryStep = 0, previewRevision = 0, formRevision = 0, checkingEntry = null, lastError = "";
    var root = S.node("section", "settings-stack"), form = S.node("div", "settings-stack");
    var add = S.button("新建提醒", null, {}, null, "small"); root.appendChild(add); root.appendChild(form);
    var message = S.node("p", "feedback-message"); message.setAttribute("role", "status"); root.appendChild(message);
    var title, prompt, mode, timingContainer, preview, submit, cancel;
    form.hidden = true;
    form.addEventListener("input", onInput); form.addEventListener("change", onInput);
    add.addEventListener("click", function () {
      if (!active || !context.sessionID || !context.connected) return;
      expanded = true; current = drafts[context.sessionID] || fresh(context.sessionID);
      build();
    });

    function fresh(sessionID) { return { sessionId: sessionID, title: "", prompt: "", kind: "at", timings: {} }; }
    function save() {
      if (!current) return false;
      drafts[current.sessionId] = current;
      try { global.localStorage.setItem(storageKey, JSON.stringify(drafts)); return true; }
      catch (_) { message.textContent = "无法保存提醒草稿，请检查本地存储空间。"; return false; }
    }
    function clear(entry) {
      if (drafts[entry.sessionId] !== entry) return;
      delete drafts[entry.sessionId];
      try { global.localStorage.setItem(storageKey, JSON.stringify(drafts)); }
      catch (_) { message.textContent = "无法更新提醒草稿，请检查本地存储空间。"; }
    }
    function capture() {
      if (!current || !title || current.operation) return;
      current.title = title.control.value; current.prompt = prompt.control.value;
      if (timing) current.timings[current.kind] = timing.snapshot();
      save();
    }
    function build() {
      formRevision++; S.clear(form); title = null; prompt = null; timing = null;
      form.hidden = !expanded || !current; add.hidden = expanded;
      if (form.hidden) { sync(); return; }
      title = S.textField("名称", current.title, "例如：整理本周记录"); title.control.maxLength = 120;
      prompt = S.textAreaField("提醒内容", current.prompt, "希望在提醒时执行什么");
      form.appendChild(title.wrapper); form.appendChild(prompt.wrapper);
      mode = S.selectField("重复", current.kind, [
        { id: "at", title: "仅一次" }, { id: "daily", title: "每天" },
        { id: "weekly", title: "每周" }, { id: "every", title: "按间隔" },
        { id: "cron", title: "高级时间规则" }
      ], function (value) {
        if (!current || current.operation || value === current.kind) return;
        if (timing) current.timings[current.kind] = timing.snapshot();
        current.kind = value; build(); save();
      });
      form.appendChild(mode.wrapper); timingContainer = S.node("div", "settings-stack"); form.appendChild(timingContainer);
      timing = timingEditor(defaults(current.kind));
      timing.restore(current.timings[current.kind]); timingContainer.appendChild(timing.form);
      preview = S.node("p", "hint"); preview.setAttribute("role", "status"); form.appendChild(preview);
      var actions = S.node("div", "form-actions"); form.appendChild(actions);
      submit = S.button("创建提醒", null, {}, null, "small"); cancel = S.button("取消", null, {}, null, "small");
      actions.appendChild(submit); actions.appendChild(cancel);
      submit.addEventListener("click", submitForm);
      cancel.addEventListener("click", function () {
        if (!current || current.operation) return;
        clear(current); current = null; expanded = false; message.textContent = ""; build();
      });
      sync(); queuePreview();
    }
    function onInput() { capture(); queuePreview(); }
    function sync() {
      add.disabled = !active || !context.connected || !context.sessionID;
      add.title = context.sessionID ? "" : "打开会话后可创建提醒";
      if (!current || !title) return;
      var disabled = !!current.operation || !context.connected;
      title.control.disabled = disabled; prompt.control.disabled = disabled; mode.control.disabled = disabled;
      timing.setDisabled(disabled); submit.disabled = disabled; cancel.disabled = !!current.operation;
      if (current.operation) message.textContent = "正在核对提醒是否创建，请稍候…";
    }
    function queuePreview() {
      if (previewTimer) global.clearTimeout(previewTimer);
      var revision = ++previewRevision, formVersion = formRevision;
      previewTimer = global.setTimeout(function () {
        if (!active || !timing || revision !== previewRevision || formVersion !== formRevision) return;
        var change;
        try { change = timing.change(true); }
        catch (error) { preview.textContent = error.message; return; }
        preview.textContent = "正在计算下次提醒…";
        T.call("schedule.preview", { change: change }).then(function (result) {
          if (revision !== previewRevision || formVersion !== formRevision) return;
          var date = result && new Date(result.scheduledAt);
          preview.textContent = date && !isNaN(date.getTime()) ? "下次提醒：" + date.toLocaleString() : "无法计算下次提醒。";
        }).catch(function (error) {
          if (revision === previewRevision && formVersion === formRevision) preview.textContent = error.message || "无法计算下次提醒。";
        });
      }, 400);
    }
    function submitForm() {
      if (!current || current.operation || !context.connected) return;
      capture();
      var name = current.title.trim(), text = current.prompt.trim(), change;
      if (!name || name.length > 120) { message.textContent = "名称须为 1 至 120 个字符。"; return; }
      if (!text) { message.textContent = "请填写提醒内容。"; return; }
      try { change = timing.change(true); } catch (error) { message.textContent = error.message; return; }
      current.operation = { sessionId: current.sessionId, requestId: T.requestID(), title: name,
        prompt: text, change: change, resent: false };
      if (!save()) { delete current.operation; return; }
      retryStep = 0; sync(); dispatch(current);
    }
    function dispatch(entry) {
      var request = entry.operation;
      if (!request) return;
      T.call("schedule.create", request, { timeoutMs: 10000 }).then(function (result) {
        if (entry.operation !== request) return;
        if (result && result.state === "accepted") { accepted(entry); return; }
        check(entry);
      }).catch(function (error) {
        if (entry.operation !== request) return;
        lastError = error && error.message || "创建提醒失败。";
        check(entry);
      });
    }
    function check(entry) {
      if (!active || current !== entry || !entry.operation || checkingEntry === entry || !context.connected) return;
      var request = entry.operation; checkingEntry = entry;
      T.call("schedule.createStatus", { sessionId: request.sessionId, requestId: request.requestId }).then(function (result) {
        if (entry.operation !== request || current !== entry) return;
        var action = statusAction(result, request.resent);
        if (action === "accepted") { accepted(entry); return; }
        if (action === "retry") {
          request.resent = true;
          if (save()) global.setTimeout(function () { dispatch(entry); }, 0);
          return;
        }
        if (action === "failed") {
          delete entry.operation;
          save(); sync(); message.textContent = lastError || "提醒尚未创建，请检查内容后重试。";
          return;
        }
        scheduleCheck(entry);
      }).catch(function () { if (entry.operation === request) scheduleCheck(entry); })
        .finally(function () { if (checkingEntry === entry) checkingEntry = null; });
    }
    function scheduleCheck(entry) {
      if (retryTimer) global.clearTimeout(retryTimer);
      if (!active || current !== entry || !entry.operation) return;
      var delay = delays[Math.min(retryStep++, delays.length - 1)];
      retryTimer = global.setTimeout(function () { retryTimer = null; check(entry); }, delay);
    }
    function accepted(entry) {
      if (retryTimer) global.clearTimeout(retryTimer); retryTimer = null;
      clear(entry);
      if (current !== entry) return;
      current = null; expanded = false; message.textContent = "提醒已创建。"; build();
      if (options.onCreated) options.onCreated();
    }
    function setActive(value) {
      active = value;
      if (!value) {
        capture(); if (retryTimer) global.clearTimeout(retryTimer); if (previewTimer) global.clearTimeout(previewTimer);
        retryTimer = null; previewTimer = null; previewRevision++; return;
      }
      context = options.getContext();
      current = context.sessionID && drafts[context.sessionID] || null;
      expanded = !!current; message.textContent = ""; retryStep = 0; build();
      if (current && current.operation) check(current);
    }
    function update(next) {
      context = next; sync();
      if (active && current && current.operation && context.connected) check(current);
    }
    return { root: root, setActive: setActive, update: update };
  }
  global.CodexBridgeDesktopEmbeddedDSHScheduleCreate = { create: create, defaults: defaults, statusAction: statusAction };
}(window));
