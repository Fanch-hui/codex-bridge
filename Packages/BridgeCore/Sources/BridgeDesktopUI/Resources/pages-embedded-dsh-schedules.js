(function (global) {
  "use strict";
  var S = global.CodexBridgeDesktopPageSupport;

  function localDateTime(value) {
    var date = new Date(value);
    if (isNaN(date.getTime())) return "";
    function two(number) { return String(number).padStart(2, "0"); }
    return date.getFullYear() + "-" + two(date.getMonth() + 1) + "-" + two(date.getDate()) + "T"
      + two(date.getHours()) + ":" + two(date.getMinutes()) + ":" + two(date.getSeconds());
  }
  function normalizedTime(value) {
    var match = /^(\d{2}):(\d{2})(?::(\d{2})(?:\.(\d{1,3}))?)?$/.exec(value);
    if (!match) return value;
    var fraction = (match[4] || "").replace(/0+$/, "");
    return match[1] + ":" + match[2] + ":" + (match[3] || "00") + (fraction ? "." + fraction : "");
  }
  function intervalLabel(seconds) {
    if (seconds % 86400 === 0) return "每 " + seconds / 86400 + " 天";
    if (seconds % 3600 === 0) return "每 " + seconds / 3600 + " 小时";
    if (seconds % 60 === 0) return "每 " + seconds / 60 + " 分钟";
    return "每 " + seconds + " 秒";
  }
  function timingEditor(record) {
    var form = S.node("div", "settings-stack"), fields = {}, controls = [];
    function add(key, label, value, placeholder, container) {
      var field = S.textField(label, String(value), placeholder);
      fields[key] = field.control; controls.push(field.control); (container || form).appendChild(field.wrapper);
      return field.control;
    }
    if (record.kind === "at" || record.kind === "after") {
      var localAt = localDateTime(record.scheduledAt), atControl = add("at", "提醒时间", localAt);
      atControl.type = "datetime-local"; atControl.step = "1";
      localAt = atControl.value;
    } else if (record.kind === "every") {
      var units = record.everySeconds % 86400 === 0 ? "days" : record.everySeconds % 3600 === 0 ? "hours"
        : record.everySeconds % 60 === 0 ? "minutes" : "seconds";
      var divisors = { seconds: 1, minutes: 60, hours: 3600, days: 86400 };
      var interval = add("seconds", "重复间隔", record.everySeconds / divisors[units]);
      interval.type = "number"; interval.inputMode = "numeric"; interval.min = "1"; interval.step = "1";
      var unit = S.selectField("单位", units, [
        { id: "minutes", title: "分钟" }, { id: "hours", title: "小时" },
        { id: "days", title: "天" }, { id: "seconds", title: "秒" }
      ], function () {});
      fields.units = unit.control; controls.push(unit.control); form.appendChild(unit.wrapper);
    } else if (record.kind === "daily" || record.kind === "weekly") {
      var timeControl = add("time", "时间", record.time); timeControl.type = "time"; timeControl.step = "1";
      var timeOptions = S.node("details", "agent-details");
      timeOptions.appendChild(S.node("summary", null, "时区"));
      add("zone", "时区（UTC 或 IANA）", record.timeZone, "例如 Asia/Shanghai", timeOptions);
      form.appendChild(timeOptions);
      if (record.kind === "weekly") {
        var choices = S.node("div", "form-actions"), days = ["一", "二", "三", "四", "五", "六", "日"];
        choices.setAttribute("role", "group"); choices.setAttribute("aria-label", "每周重复日期");
        fields.days = days.map(function (day, index) {
          var label = S.node("label", "check-field"), control = S.node("input");
          control.type = "checkbox"; control.checked = record.weekdays.indexOf(index + 1) !== -1;
          controls.push(control);
          label.appendChild(control); label.appendChild(S.node("span", null, "周" + day)); choices.appendChild(label);
          return control;
        });
        form.appendChild(choices);
      }
    } else if (record.kind === "cron") {
      var cronOptions = S.node("details", "agent-details");
      cronOptions.appendChild(S.node("summary", null, "高级时间规则"));
      add("expression", "Cron 表达式", record.expression, "", cronOptions);
      add("zone", "时区（UTC 或 IANA）", record.timeZone, "例如 Asia/Shanghai", cronOptions);
      form.appendChild(cronOptions);
    }
    function change(force) {
      if (fields.at) {
        var at = fields.at.value.trim();
        if (!force && at === localAt) return;
        var parsed = new Date(at);
        if (!at || isNaN(parsed.getTime())) throw new Error("请填写有效的提醒时间。");
        return { kind: "at", at: parsed.toISOString() };
      }
      if (fields.seconds) {
        var value = fields.seconds.value.trim(), seconds = Number(value) * divisors[fields.units.value];
        if (!/^\d+$/.test(value) || !Number.isSafeInteger(seconds) || seconds < 60) throw new Error("重复间隔须为至少 60 秒的整数。");
        if (force || seconds !== record.everySeconds) return { kind: "every", every_seconds: seconds };
        return;
      }
      if (fields.time) {
        var time = fields.time.value.trim(), zone = fields.zone.value.trim();
        var selected = fields.days && fields.days.reduce(function (result, control, index) {
          if (control.checked) result.push(index + 1);
          return result;
        }, []);
        if (!time || !zone) throw new Error("请填写时间和时区。");
        if (selected && !selected.length) throw new Error("请至少选择一个重复日期。");
        if (!force && normalizedTime(time) === normalizedTime(record.time) && zone === record.timeZone
            && (!selected || selected.join(",") === record.weekdays.join(","))) return;
        if (selected) return { kind: "weekly", weekly: { time: time, time_zone: zone, weekdays: selected } };
        return { kind: "daily", daily: { time: time, time_zone: zone } };
      }
      if (fields.expression) {
        var expression = fields.expression.value.trim(), cronZone = fields.zone.value.trim();
        if (!expression || !cronZone) throw new Error("请填写 Cron 表达式和时区。");
        if (force || expression !== record.expression || cronZone !== record.timeZone) {
          return { kind: "cron", cron: { expression: expression, time_zone: cronZone } };
        }
      }
    }
    return { form: form, change: change, snapshot: function () {
      var value = {};
      Object.keys(fields).forEach(function (key) {
        value[key] = key === "days" ? fields.days.map(function (control) { return control.checked; }) : fields[key].value;
      });
      return value;
    }, restore: function (value) {
      if (!value || typeof value !== "object") return;
      Object.keys(fields).forEach(function (key) {
        if (key === "days" && Array.isArray(value.days)) {
          fields.days.forEach(function (control, index) { control.checked = value.days[index] === true; });
        } else if (typeof value[key] === "string") fields[key].value = value[key];
      });
    }, setDisabled: function (value) {
      controls.forEach(function (control) { control.disabled = value; });
    } };
  }

  function create(options) {
    var T = options.transport, context = options.getContext ? options.getContext() : {};
    var active = false, generation = 0, readRevision = 0, editRevision = 0, historyRevision = 0;
    var entries = [], editing = null, savedEdit = null, loadingEdit = false, deleting = null, writing = false;
    var draftsKey = "codexbridge.workbench.scheduleDrafts.v1", drafts = {};
    try { drafts = JSON.parse(global.localStorage.getItem(draftsKey) || "{}") || {}; } catch (_) { drafts = {}; }
    if (!drafts || Array.isArray(drafts) || typeof drafts !== "object") drafts = {};
    var catchUpKey = "codexbridge.workbench.scheduleCatchUp.v1", catchUps = {};
    try { catchUps = JSON.parse(global.localStorage.getItem(catchUpKey) || "{}") || {}; } catch (_) { catchUps = {}; }
    if (!catchUps || Array.isArray(catchUps) || typeof catchUps !== "object") catchUps = {};
    var history = null;
    var dialog = S.node("dialog", "component-dialog");
    dialog.setAttribute("aria-labelledby", "dsh-schedules-title");
    var header = S.node("header", "dialog-header"), heading = S.node("h2", null, "任务与提醒");
    heading.id = "dsh-schedules-title"; header.appendChild(heading); dialog.appendChild(header);
    var body = S.node("div", "dialog-body settings-stack"); dialog.appendChild(body);
    var notice = S.node("p", "feedback-message"); notice.setAttribute("role", "status"); body.appendChild(notice);
    var creator = global.CodexBridgeDesktopEmbeddedDSHScheduleCreate.create({
      transport: T, getContext: function () { return context; }, onCreated: function () { if (active) refresh(); }
    });
    body.appendChild(creator.root);
    var list = S.node("div", "settings-stack"); body.appendChild(list);
    var footer = S.node("footer", "dialog-footer"); dialog.appendChild(footer);
    var refreshButton = button("刷新", refresh), closeButton = button("关闭", close);
    footer.appendChild(refreshButton); footer.appendChild(closeButton);
    dialog.addEventListener("cancel", invalidate);
    dialog.addEventListener("close", function () { if (!dialog.open) invalidate(); });

    function button(label, handler) {
      var element = S.button(label, null, {}, null, "small");
      element.addEventListener("click", handler); return element;
    }
    function rpc(endpoint, args) {
      return T.call("client.rpc", { channel: "/api", endpoint: endpoint, payload: { args: args } }).then(function (result) {
        if (!result || result.ok !== true) throw new Error(result && result.error && result.error.message || "操作失败，请重试。");
        return result.value;
      });
    }
    function showError(error) {
      notice.textContent = error && error.message || "操作失败，请重试。";
      if (options.onError) options.onError(error);
    }
    function draftID(editor) { return editor.item.sessionId + "\u001f" + editor.item.id; }
    function persistDrafts() {
      try { global.localStorage.setItem(draftsKey, JSON.stringify(drafts)); }
      catch (_) { if (active) notice.textContent = "无法保存提醒草稿，请检查本地存储空间。"; }
    }
    function persistEdit(editor) {
      if (!editor) return;
      drafts[draftID(editor)] = { item: { id: editor.item.id, sessionId: editor.item.sessionId },
        sourceSessionID: editor.sourceSessionID, expected: editor.expected, timingBaseline: editor.timingBaseline,
        title: editor.title.value, prompt: editor.prompt.value, timing: editor.timing.snapshot(), updatedAt: Date.now() };
      persistDrafts();
    }
    function removeDraft(editor) {
      if (!editor) return;
      delete drafts[draftID(editor)]; persistDrafts();
    }
    function invalidate() {
      if (!active) return;
      creator.setActive(false);
      if (editing) { savedEdit = editing; persistEdit(editing); }
      active = false; generation++; readRevision++; editRevision++; historyRevision++;
      editing = null; deleting = null; loadingEdit = false; history = null;
    }
    function close() {
      invalidate();
      if (dialog.open) dialog.close();
    }
    function open() {
      if (active) return;
      active = true; generation++; entries = []; editing = null; deleting = null;
      if (!dialog.open) dialog.showModal();
      creator.setActive(true);
      render();
      if (!context.connected) { notice.textContent = "正在连接工作台。"; render(); return; }
      refresh();
    }
    function update(next) {
      var changedSession = context.sessionID !== next.sessionID;
      var changedConnection = !!context.connected !== !!next.connected;
      context = next;
      if (!active) return;
      if (changedSession) { close(); return; }
      creator.update(context);
      if (!changedConnection) return;
      if (editing) { savedEdit = editing; persistEdit(editing); }
      generation++; readRevision++; editRevision++; historyRevision++;
      editing = null; deleting = null; loadingEdit = false; history = null; entries = [];
      if (context.connected) refresh();
      else { notice.textContent = "工作台连接已断开。"; render(); }
    }
    function refresh() {
      if (!active || !context.connected || editing || deleting || loadingEdit) return;
      var ticket = generation, revision = ++readRevision;
      historyRevision++; history = null; render();
      notice.textContent = "正在读取任务与提醒…"; refreshButton.disabled = true;
      return rpc("schedule/catalog", {}).then(function (rows) {
        if (!active || ticket !== generation || revision !== readRevision) return;
        if (!Array.isArray(rows)) throw new Error("任务与提醒数据不可用。");
        entries = rows;
        reconcileCatchUps(rows);
        if (savedEdit && savedEdit.sourceSessionID === context.sessionID
            && rows.some(function (item) { return item.id === savedEdit.item.id && item.sessionId === savedEdit.item.sessionId; })) {
          editing = savedEdit; savedEdit = null;
        }
        if (!editing) {
          var saved = Object.values(drafts).filter(function (draft) {
            return draft && draft.item && draft.expected && draft.sourceSessionID === context.sessionID;
          }).sort(function (a, b) { return (b.updatedAt || 0) - (a.updatedAt || 0); }).find(function (draft) {
            return rows.some(function (item) { return item.id === draft.item.id && item.sessionId === draft.item.sessionId; });
          });
          if (saved) {
            var current = rows.find(function (item) { return item.id === saved.item.id && item.sessionId === saved.item.sessionId; });
            try {
              editing = makeEditor(current, saved.timingBaseline || saved.expected);
              editing.expected = saved.expected;
              editing.title.value = saved.title || ""; editing.prompt.value = saved.prompt || "";
              editing.timing.restore(saved.timing); editing.refreshPreview();
            } catch (_) { editing = null; }
          }
        }
        notice.textContent = rows.length ? "" : "暂无任务与提醒。"; render();
        if (editing && editing.conflictPending) showConflict(editing, ticket);
      }).catch(function (error) {
        if (active && ticket === generation && revision === readRevision) showError(error);
      }).finally(function () {
        if (active && ticket === generation && revision === readRevision) refreshButton.disabled = !!editing || !!deleting || loadingEdit || writing;
      });
    }
    function rule(item) {
      if (item.kind === "every") return intervalLabel(item.everySeconds);
      if (item.kind === "daily") return "每天 " + item.time + " · " + item.timeZone;
      if (item.kind === "weekly") {
        var days = ["", "一", "二", "三", "四", "五", "六", "日"];
        return "每周" + (item.weekdays || []).map(function (day) { return days[day]; }).join("、") + " " + item.time + " · " + item.timeZone;
      }
      if (item.kind === "cron") return "自定义时间规则 · " + item.timeZone;
      return "单次提醒";
    }
    function displayTime(value) {
      var date = new Date(value);
      return isNaN(date.getTime()) ? value : date.toLocaleString();
    }
    function sessionLabel(item) {
      if (item.sessionId === context.sessionID) return context.title || "当前会话";
      var title = options.getSessionTitle && options.getSessionTitle(item.sessionId);
      return title || "会话 " + item.sessionId;
    }
    function render() {
      S.clear(list);
      entries.forEach(function (item) {
        var card = S.node("section", "settings-card");
        card.appendChild(S.node("strong", null, item.title));
        var status = item.status === "active" ? "下次提醒"
          : item.status === "paused" ? "已停用 · 原计划" : "已结束 · 计划时间";
        card.appendChild(S.node("p", "hint", status + "：" + displayTime(item.scheduledAt) + " · " + rule(item)));
        card.appendChild(S.node("p", "hint", sessionLabel(item)));
        card.appendChild(S.node("p", "feedback-message", item.prompt));
        if (item.missedAt) card.appendChild(S.node("p", "hint", "错过的提醒：" + displayTime(item.missedAt)));
        var actions = S.node("div", "form-actions"); card.appendChild(actions);
        if (deleting === item.id) {
          var confirmDelete = button("确认删除", function () { remove(item); });
          var cancelDelete = button("取消", function () { deleting = null; render(); });
          confirmDelete.disabled = writing; cancelDelete.disabled = writing;
          actions.appendChild(confirmDelete); actions.appendChild(cancelDelete);
        } else {
          var editButton = button("编辑", function () { startEdit(item); });
          var deleteButton = button("删除", function () { readRevision++; deleting = item.id; notice.textContent = ""; render(); });
          editButton.disabled = ["active", "paused"].indexOf(item.status) === -1 || !!editing || !!deleting || loadingEdit || writing;
          deleteButton.disabled = !!editing || !!deleting || loadingEdit || writing;
          actions.appendChild(editButton); actions.appendChild(deleteButton);
          if (item.status === "active" || item.status === "paused") {
            var isPaused = item.status === "paused";
            var pauseButton = button(isPaused ? "启用" : "停用", function () { setPaused(item, !isPaused); });
            pauseButton.disabled = !!editing || !!deleting || loadingEdit || writing;
            actions.appendChild(pauseButton);
          }
          if (item.missedAt) {
            var catchUpButton = button(catchUps[catchUpID(item)] ? "核对补做" : "补做", function () { catchUp(item); });
            var skipButton = button("跳过", function () { discardMissed(item); });
            catchUpButton.disabled = !!editing || !!deleting || loadingEdit || writing;
            skipButton.disabled = !!editing || !!deleting || loadingEdit || writing || !!catchUps[catchUpID(item)];
            actions.appendChild(catchUpButton); actions.appendChild(skipButton);
          }
          var historyButton = button(history && history.item.id === item.id ? "收起记录" : "投递记录", function () {
            toggleHistory(item);
          });
          historyButton.setAttribute("aria-expanded", history && history.item.id === item.id ? "true" : "false");
          historyButton.disabled = !!deleting || loadingEdit || writing;
          actions.appendChild(historyButton);
        }
        if (editing && editing.item.id === item.id) card.appendChild(editing.form);
        if (history && history.item.id === item.id) renderHistory(card);
        list.appendChild(card);
      });
      refreshButton.disabled = !!editing || !!deleting || loadingEdit || writing;
    }
    function renderHistory(card) {
      var section = S.node("div", "settings-stack");
      history.element = section; card.appendChild(section); renderHistoryContent();
    }
    function renderHistoryContent() {
      var section = history.element; S.clear(section);
      if (history.loaded && !history.records.length) section.appendChild(S.node("p", "hint", "暂无投递记录。"));
      history.records.forEach(function (entry) {
        var row = S.node("div", "settings-card");
        row.appendChild(S.node("p", "hint", "投递时间：" + displayTime(entry.deliveredAt)));
        row.appendChild(S.node("p", "hint", "计划时间：" + displayTime(entry.scheduledAt)));
        if (entry.prompt !== undefined) row.appendChild(S.node("p", "feedback-message", entry.prompt));
        section.appendChild(row);
      });
      if (history.unavailable) section.appendChild(S.node("p", "hint", history.pruned
        ? "更早的投递记录可能不完整，部分记录已按保留规则清理。" : "更早的投递记录可能不完整。"));
      if (history.error) section.appendChild(S.node("p", "feedback-message", history.error));
      if (history.loading) section.appendChild(S.node("p", "hint", "正在读取投递记录…"));
      else if (history.error && !history.stale) section.appendChild(button("重试读取", readHistory));
      else if (!history.error && history.nextBefore) section.appendChild(button("加载更早记录", readHistory));
    }
    function toggleHistory(item) {
      readRevision++; historyRevision++; notice.textContent = "";
      if (history && history.item.id === item.id) { history = null; render(); return; }
      history = { item: item, records: [], loaded: false, loading: false, error: "", nextBefore: null,
        unavailable: false, pruned: false, stale: false };
      readHistory();
    }
    function readHistory() {
      if (!history || history.loading) return;
      var current = history, ticket = generation, revision = ++historyRevision;
      var request = { sessionId: current.item.sessionId, id: current.item.id, limit: 20 };
      if (current.nextBefore) request.before = current.nextBefore;
      current.loading = true; current.error = ""; render();
      return rpc("schedule/history", { request: request }).then(function (result) {
        if (!active || ticket !== generation || revision !== historyRevision || history !== current) return;
        if (!result || !Array.isArray(result.records)) throw resultError(result);
        if (result.id !== current.item.id) throw new Error("投递记录与当前提醒不一致。");
        current.records = current.records.concat(result.records); current.loaded = true;
        current.nextBefore = result.nextBefore || null;
        current.unavailable = current.unavailable || result.earlierRecordsUnavailable === true;
        current.pruned = current.pruned || result.earlierRecordsPruned === true;
      }).catch(function (error) {
        if (!active || ticket !== generation || revision !== historyRevision || history !== current) return;
        current.error = error && error.message || "读取投递记录失败。";
        current.stale = error && error.code === "delivery_cursor_not_found";
        if (options.onError) options.onError(error);
      }).finally(function () {
        if (active && ticket === generation && revision === historyRevision && history === current) {
          current.loading = false; renderHistoryContent();
        }
      });
    }
    function startEdit(item) {
      if (loadingEdit || editing || writing) return;
      var ticket = generation, revision = ++editRevision;
      readRevision++; loadingEdit = true; notice.textContent = "正在读取提醒…"; render();
      return rpc("schedule/list", { request: { sessionId: item.sessionId } }).then(function (records) {
        if (!active || ticket !== generation || revision !== editRevision) return;
        if (!Array.isArray(records)) throw new Error("提醒数据不可用。");
        var record = records.find(function (entry) { return entry.id === item.id; });
        if (!record) throw new Error("提醒已结束或不存在，请刷新后查看。");
        editing = makeEditor(item, record); notice.textContent = "";
      }).catch(function (error) {
        if (active && ticket === generation && revision === editRevision) showError(error);
      }).finally(function () {
        if (active && ticket === generation && revision === editRevision) { loadingEdit = false; render(); }
      });
    }
    function makeEditor(item, record) {
      var form = S.node("div", "settings-stack");
      var title = S.textField("名称", record.title), prompt = S.textAreaField("提醒内容", record.prompt);
      title.control.maxLength = 120; form.appendChild(title.wrapper); form.appendChild(prompt.wrapper);
      var timing = timingEditor(record); form.appendChild(timing.form);
      var preview = S.node("p", "hint", "下次提醒：" + displayTime(record.scheduledAt));
      var conflict = S.node("div", "settings-stack");
      preview.setAttribute("role", "status"); form.appendChild(preview); form.appendChild(conflict);
      var previewTimer = null, previewRevision = 0;
      function previewTiming() {
        if (!active || editing !== editor) return;
        var revision = ++previewRevision, change;
        try { change = timing.change(); }
        catch (failure) { preview.textContent = failure.message; return; }
        if (!change) { preview.textContent = "下次提醒：" + displayTime(editor.expected.scheduledAt); return; }
        preview.textContent = "正在计算下次提醒…";
        T.call("schedule.preview", { change: change }).then(function (result) {
          if (revision !== previewRevision) return;
          preview.textContent = result && result.scheduledAt ? "下次提醒：" + displayTime(result.scheduledAt) : "无法计算下次提醒。";
        }).catch(function (failure) {
          if (revision === previewRevision) preview.textContent = failure && failure.message || "无法计算下次提醒。";
        });
      }
      function queuePreview() {
        if (previewTimer) global.clearTimeout(previewTimer);
        previewTimer = global.setTimeout(previewTiming, 400);
      }
      timing.form.addEventListener("input", queuePreview); timing.form.addEventListener("change", queuePreview);
      var actions = S.node("div", "form-actions"); form.appendChild(actions);
      var save = button("保存", function () { saveEdit(); });
      var cancel = button("取消编辑", function () {
        if (!writing) { removeDraft(editing); editing = null; savedEdit = null; notice.textContent = ""; render(); }
      });
      actions.appendChild(save); actions.appendChild(cancel);
      var editor = { item: item, sourceSessionID: context.sessionID, expected: record, timingBaseline: record,
        form: form, title: title.control, prompt: prompt.control,
        timing: timing, save: save, cancel: cancel, conflict: conflict, conflictPending: false, refreshPreview: queuePreview };
      form.addEventListener("input", function () { persistEdit(editor); });
      form.addEventListener("change", function () { persistEdit(editor); });
      return editor;
    }
    function saveEdit() {
      if (!editing || editing.conflictPending || writing) return;
      var current = editing, title = current.title.value.trim(), prompt = current.prompt.value.trim();
      if (!title || title.length > 120) { notice.textContent = "名称须为 1 至 120 个字符。"; return; }
      if (!prompt) { notice.textContent = "请填写提醒内容。"; return; }
      var change;
      try { change = current.timing.change(); } catch (error) { notice.textContent = error.message; return; }
      return write("正在保存…", function () {
        var request = { sessionId: current.item.sessionId, id: current.item.id,
          expected: current.expected, title: title, prompt: prompt };
        if (change) request.change = change;
        return rpc("schedule/update", { request: request });
      }, function (result) {
        if (!result || typeof result.updated !== "boolean" || !result.record) throw resultError(result);
        removeDraft(editing); editing = null; savedEdit = null;
      });
    }
    function remove(item) {
      if (writing || deleting !== item.id) return;
      return write("正在删除…", function () {
        return rpc("schedule/delete", { request: { sessionId: item.sessionId, id: item.id } });
      }, function (result) {
        if (!result || result.deleted !== true) throw resultError(result);
        deleting = null;
      });
    }
    function setPaused(item, paused) {
      if (writing) return;
      return write(paused ? "正在停用…" : "正在启用…", function () {
        return T.call(paused ? "schedule.pause" : "schedule.resume", { sessionId: item.sessionId, id: item.id });
      }, function (result) {
        if (!result || !result.status) throw new Error("提醒状态不可用，请刷新后查看。");
      });
    }
    function catchUpID(item) { return item.sessionId + "\u001f" + item.id; }
    function persistCatchUps() {
      try { global.localStorage.setItem(catchUpKey, JSON.stringify(catchUps)); return true; }
      catch (_) { notice.textContent = "无法保存补做进度，请检查本地存储空间。"; return false; }
    }
    function reconcileCatchUps(rows) {
      var changed = false;
      rows.forEach(function (item) {
        var key = catchUpID(item), pending = catchUps[key];
        if (pending && typeof pending === "object" && pending.missedAt !== item.missedAt) {
          delete catchUps[key]; changed = true;
        }
      });
      if (changed) persistCatchUps();
    }
    function catchUp(item) {
      if (writing) return;
      var key = catchUpID(item), existing = catchUps[key];
      var requestID = typeof existing === "string" ? existing : existing && existing.requestId || T.requestID();
      catchUps[key] = { requestId: requestID, missedAt: item.missedAt };
      if (!persistCatchUps()) { if (!existing) delete catchUps[key]; else catchUps[key] = existing; return; }
      return write("正在补做…", function () {
        return T.call("schedule.catchUp", { sessionId: item.sessionId, id: item.id, requestId: requestID });
      }, function (result) {
        if (!result || result.accepted !== true) throw new Error("补做状态待确认，请再次核对。");
        delete catchUps[key]; persistCatchUps();
      });
    }
    function discardMissed(item) {
      if (writing || catchUps[catchUpID(item)]) return;
      return write("正在跳过…", function () {
        return T.call("schedule.discardMissed", { sessionId: item.sessionId, id: item.id });
      }, function (result) {
        if (!result || typeof result.discarded !== "boolean") throw new Error("提醒状态不可用，请刷新后查看。");
      });
    }
    function resultError(result) {
      var code = result && result.code;
      if (code === "schedule_conflict") {
        var conflictError = new Error("提醒已变更，正在读取最新设置。");
        conflictError.code = code; return conflictError;
      }
      if (code === "schedule_ended") return new Error("提醒已结束，请刷新后查看。");
      if (code === "schedule_not_found") return new Error("提醒不存在，请刷新后查看。");
      if (code === "delivery_cursor_not_found") {
        var cursorError = new Error("投递记录已变化，请收起后重新查看。");
        cursorError.code = code; return cursorError;
      }
      if (code === "invalid_time_zone") return new Error("时区无效，请填写 UTC 或 IANA 时区。");
      if (code === "not_future") return new Error("提醒时间须晚于当前时间。");
      if (code === "frequency_too_high") return new Error("重复间隔须至少为 60 秒。");
      if (code === "invalid_rule") return new Error("时间规则无效。" + (result.message ? " " + result.message : ""));
      return new Error(result && result.message || "操作失败，请重试。");
    }
    function showConflict(current, ticket) {
      current.conflictPending = true; current.save.disabled = true;
      notice.textContent = "提醒已变更，正在读取最新设置。";
      S.clear(current.conflict);
      return rpc("schedule/list", { request: { sessionId: current.item.sessionId } }).then(function (records) {
        if (!active || ticket !== generation || editing !== current) return;
        var latest = Array.isArray(records) && records.find(function (entry) { return entry.id === current.item.id; });
        if (!latest) throw new Error("提醒已结束或不存在，已保留当前编辑内容。");
        notice.textContent = "提醒已变更，比较后选择如何继续。";
        current.conflict.appendChild(S.node("strong", null, "最新设置"));
        function difference(label, before, after) {
          if (before === after) return;
          current.conflict.appendChild(S.node("p", "hint", label + "：" + String(before || "").slice(0, 300)
            + " → " + String(after || "").slice(0, 300)));
        }
        difference("名称", current.expected.title, latest.title);
        difference("内容", current.expected.prompt, latest.prompt);
        difference("时间", rule(current.expected) + " · " + displayTime(current.expected.scheduledAt),
          rule(latest) + " · " + displayTime(latest.scheduledAt));
        var actions = S.node("div", "form-actions"); current.conflict.appendChild(actions);
        actions.appendChild(button("使用我的修改", function () {
          current.expected = latest; current.conflictPending = false; S.clear(current.conflict);
          persistEdit(current); current.refreshPreview();
          current.save.disabled = false; notice.textContent = "请检查内容后保存。";
        }));
        actions.appendChild(button("使用最新设置", function () {
          editing = makeEditor(current.item, latest); persistEdit(editing); notice.textContent = "已载入最新设置。"; render();
        }));
      }).catch(function (failure) {
        if (!active || ticket !== generation || editing !== current) return;
        notice.textContent = failure && failure.message || "读取最新提醒失败，已保留编辑内容。";
        var retry = button("重新读取", function () { showConflict(current, generation); });
        current.conflict.appendChild(retry);
      });
    }
    function write(message, operation, complete) {
      var ticket = generation, succeeded = false;
      writing = true; notice.textContent = message;
      if (editing) setEditorDisabled(editing, true);
      render();
      return Promise.resolve().then(operation).then(function (result) {
        if (active && ticket === generation) { complete(result); succeeded = true; }
      }).catch(function (error) {
        if (active && ticket === generation && error && error.code === "schedule_conflict" && editing) {
          return showConflict(editing, ticket);
        }
        if (active && ticket === generation) { if (!editing) deleting = null; showError(error); }
      }).finally(function () {
        writing = false;
        if (!active) return;
        if (ticket !== generation) { refresh(); return; }
        if (editing) { setEditorDisabled(editing, false); render(); return; }
        render();
        if (succeeded) refresh();
      });
    }
    function setEditorDisabled(editor, disabled) {
      editor.title.disabled = disabled; editor.prompt.disabled = disabled;
      editor.save.disabled = disabled || editor.conflictPending; editor.cancel.disabled = disabled; editor.timing.setDisabled(disabled);
    }
    function dispose() { close(); dialog.remove(); }
    return { root: dialog, dialog: dialog, open: open, close: close, update: update, dispose: dispose };
  }

  global.CodexBridgeDesktopEmbeddedDSHSchedules = {
    create: create, timingEditor: timingEditor, localDateTime: localDateTime,
    normalizedTime: normalizedTime, intervalLabel: intervalLabel
  };
}(window));
