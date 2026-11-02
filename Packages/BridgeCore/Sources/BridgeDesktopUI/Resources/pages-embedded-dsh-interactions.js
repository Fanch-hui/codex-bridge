(function (global) {
  "use strict";
  var S = global.CodexBridgeDesktopPageSupport, T = global.CodexBridgeDesktopEmbeddedDSHTransport;

  function create(interaction, subagents, showError) {
    var requests = new Map(), deferred = new Map(), agentNodes = new Map(), sessionID = null, listGeneration = 0;
    var questionDraftKey = "codexbridge.workbench.question-drafts.v1", questionDrafts = {};
    try { questionDrafts = JSON.parse(global.localStorage.getItem(questionDraftKey) || "{}") || {}; } catch (_) {}
    var childDraftKey = "codexbridge.workbench.child-drafts.v1", childDrafts = {}, childTimers = new Map();
    try { childDrafts = JSON.parse(global.localStorage.getItem(childDraftKey) || "{}") || {}; } catch (_) {}
    var active = false, timer = null, activeGeneration = 0;
    var bridge = global.CodexBridgeDesktopEmbeddedDSHBridge.create(interaction, function (id) {
      var row = agentNodes.get(id); return row ? row.label.textContent : id;
    }, showError);

    function button(title, action) {
      var value = S.button(title, null, {}, null, "small");
      value.addEventListener("click", action); return value;
    }
    function error(error) { showError(error); }
    function saveQuestions() { try { global.localStorage.setItem(questionDraftKey, JSON.stringify(questionDrafts)); } catch (_) {} }
    function saveChildren() { try { global.localStorage.setItem(childDraftKey, JSON.stringify(childDrafts)); } catch (_) {} }
    function draftKey(source, id) { return JSON.stringify([source, id]); }
    function childState(parent, id) {
      var key = draftKey(parent, id);
      if (!childDrafts[key]) childDrafts[key] = { parent: parent, childID: id, text: "" };
      return childDrafts[key];
    }
    function syncChild(parent, id) {
      var row = parent === sessionID && agentNodes.get(id);
      if (row && row.syncControls) row.syncControls();
    }
    function settleChild(parent, id, kind, operationID, result) {
      var state = childState(parent, id), key = kind + "ID";
      if (state[key] !== operationID) return true;
      var operation = global.CodexBridgeDesktopEmbeddedDSHOperations.snapshot(result, operationID);
      var outcome = global.CodexBridgeDesktopEmbeddedDSHOperations.outcome(operation);
      if (outcome === "pending" || outcome === "unknown") return false;
      if (kind === "stop" && outcome === "accepted") state.stopAccepted = true;
      else {
        delete state[key];
        if (kind === "send" && outcome === "accepted") { state.text = ""; state.feedback = "已发送。"; }
        else state.feedback = outcome === "cancelled" ? "操作已停止。" : "操作失败，请重试。";
      }
      saveChildren(); syncChild(parent, id);
      if (parent === sessionID) refresh();
      return true;
    }
    function reconcileChild(parent, id, kind, operationID, attempt, delay) {
      if (!active || parent !== sessionID || childTimers.has(operationID)) return;
      var state = childState(parent, id);
      if (state[kind + "ID"] !== operationID || kind === "stop" && state.stopAccepted) return;
      var delays = [1000, 2000, 4000, 8000, 15000, 30000];
      var wait = delay == null ? attempt < delays.length ? delays[attempt] : 60000 : delay;
      var timer = global.setTimeout(function () {
        childTimers.delete(operationID);
        if (!active || parent !== sessionID) return;
        T.call("operations.read", { operationIDs: [operationID] }).then(function (result) {
          if (settleChild(parent, id, kind, operationID, result)) return null;
          return T.call("operations.reconcile", { operationID: operationID }).then(function (value) {
            if (!settleChild(parent, id, kind, operationID, value)) throw new Error("操作仍在核对。");
          });
        }).catch(function () { reconcileChild(parent, id, kind, operationID, attempt + 1); });
      }, wait);
      if (timer && timer.unref) timer.unref();
      childTimers.set(operationID, timer);
    }
    function submitChild(parent, id, kind, text) {
      var state = childState(parent, id), key = kind + "ID";
      if (state[key]) return;
      var operationID = T.requestID(); state[key] = operationID; state.feedback = kind === "send" ? "正在发送…" : "正在停止…";
      if (kind === "stop") state.stopAccepted = false;
      saveChildren(); syncChild(parent, id);
      var input = { sessionId: parent, childId: id, operation: kind, requestId: operationID };
      if (kind === "send") input.text = text;
      T.call("operations.submit", { operationID: operationID, kind: "subagents.control", sessionID: parent,
        childID: id, requestID: operationID, input: input }, { timeoutMs: 10000 }).then(function (result) {
        if (!settleChild(parent, id, kind, operationID, result)) reconcileChild(parent, id, kind, operationID, 0, 10000);
      }).catch(function () { reconcileChild(parent, id, kind, operationID, 0, 0); });
    }
    function resolveRequest(id, action, payload, holder, requestSessionID) {
      if (holder.__pending) return;
      holder.__pending = true;
      var status = holder.__status || S.node("p", "hint"); holder.__status = status;
      status.setAttribute("role", "status"); status.textContent = action === "question.answer" ? "正在提交回答…" : "正在提交审批…";
      if (!status.parentNode) holder.appendChild(status);
      holder.setAttribute("aria-busy", "true");
      Array.from(holder.querySelectorAll("button")).forEach(function (control) { control.disabled = true; });
      T.call(action, payload).then(function () {
        requests.delete(id); deferred.delete(requestSessionID + ":" + id); holder.remove();
        delete questionDrafts[draftKey(requestSessionID, id)]; saveQuestions();
      }).catch(function (failure) {
        holder.__pending = false; holder.removeAttribute("aria-busy");
        Array.from(holder.querySelectorAll("button")).forEach(function (control) { control.disabled = false; });
        status.textContent = failure && failure.message || "提交失败，请重试。";
      });
    }
    function approval(value, source) {
      var id = value.requestId;
      if (!id || requests.has(id)) return;
      var holder = S.node("section", "dsh-embedded-request");
      holder.appendChild(S.node("strong", null, "需要审批 · " + sourceLabel(source) + " · " + (value.toolName || "工具操作")));
      if (value.reason) holder.appendChild(S.node("p", null, value.reason));
      var actions = S.node("div", "form-actions");
      actions.appendChild(button("允许一次", function () {
        resolveRequest(id, "approval.answer", { requestId: id, outcome: "allowed-once" }, holder, source);
      }));
      actions.appendChild(button("拒绝", function () {
        resolveRequest(id, "approval.answer", { requestId: id, outcome: "rejected" }, holder, source);
      }));
      holder.appendChild(actions); interaction.appendChild(holder); requests.set(id, holder);
    }
    function question(value, source) {
      var id = value.requestId;
      if (!id || requests.has(id)) return;
      var holder = S.node("section", "dsh-embedded-request"), fields = [];
      var savedAnswers = questionDrafts[draftKey(source, id)] || {};
      function saveAnswerDrafts() {
        var answers = {};
        fields.forEach(function (field) {
          if (field.secret) return;
          answers[field.id] = { custom: field.custom.value, selected: field.controls.filter(function (control) {
            return control.type === "checkbox" ? control.checked : !!control.value;
          }).map(function (control) { return control.value; }) };
        });
        if (Object.keys(answers).length) questionDrafts[draftKey(source, id)] = answers;
        else delete questionDrafts[draftKey(source, id)];
        saveQuestions();
      }
      holder.appendChild(S.node("strong", null, "等待回答 · " + sourceLabel(source)));
      S.safeArray(value.questions).forEach(function (item) {
        var section = S.node("div", "dsh-embedded-question");
        section.appendChild(S.node("p", null, item.question || item.header || "请选择"));
        if (item.detail) section.appendChild(S.node("p", "hint", item.detail));
        var options = S.safeArray(item.options);
        var controls = [];
        if (options.length && item.multiSelect) {
          options.forEach(function (option) {
            var label = S.node("label", "dsh-embedded-question-option"), check = S.node("input");
            check.type = "checkbox"; check.value = option.label;
            label.appendChild(check); label.appendChild(S.node("span", null, option.label));
            if (option.description) label.appendChild(S.node("span", "hint", option.description));
            section.appendChild(label); controls.push(check);
          });
        } else if (options.length) {
          var choices = [{ id: "", title: "请选择" }].concat(options.map(function (option) {
            return { id: option.label, title: option.label, detail: option.description };
          }));
          var select = S.selectField("选择", "", choices, function () {});
          section.appendChild(select.wrapper); controls.push(select.control);
        }
        var input = S.textField(options.length ? "其他回答（可选）" : "回答", "", "", "");
        if (item.isSecret) input.control.type = "password";
        section.appendChild(input.wrapper);
        var field = { id: item.id, controls: controls, custom: input.control, multiSelect: !!item.multiSelect, secret: !!item.isSecret };
        fields.push(field);
        var saved = !field.secret && savedAnswers[field.id];
        if (saved) {
          input.control.value = saved.custom || "";
          controls.forEach(function (control) {
            if (control.type === "checkbox") control.checked = S.safeArray(saved.selected).includes(control.value);
            else control.value = S.safeArray(saved.selected)[0] || "";
          });
        }
        input.control.addEventListener("input", saveAnswerDrafts);
        controls.forEach(function (control) { control.addEventListener("change", saveAnswerDrafts); });
        holder.appendChild(section);
      });
      holder.appendChild(button("提交回答", function () {
        var answers = fields.map(function (field) {
          var custom = field.custom.value.trim();
          var selected = field.controls.filter(function (control) {
            return control.type === "checkbox" ? control.checked : !!control.value;
          }).map(function (control) { return control.value; });
          if (custom && !field.multiSelect) selected = [];
          return custom ? { id: field.id, selected: selected, custom: custom } : { id: field.id, selected: selected };
        });
        if (answers.some(function (answer) { return !answer.selected.length && !answer.custom; })) {
          error(new Error("请回答每个问题。")); return;
        }
        resolveRequest(id, "question.answer", { requestId: id, answers: answers }, holder, source);
        fields.forEach(function (field) { if (field.custom.type === "password") field.custom.value = ""; });
      }));
      interaction.appendChild(holder); requests.set(id, holder);
    }
    function clearRequests() { requests.forEach(function (holder) { holder.remove(); }); requests.clear(); }
    function setSession(id) {
      if (id === sessionID) return;
      childTimers.forEach(function (timer) { global.clearTimeout(timer); }); childTimers.clear();
      sessionID = id; listGeneration++; clearRequests();
      agentNodes.forEach(function (row) { row.history.dispose(); }); agentNodes.clear(); S.clear(subagents);
      bridge.setSession(id);
      deferred.forEach(function (item) { if (item.sessionID === id) display(item); });
      if (id && active) { refresh(); resumeChildOperations(); }
    }
    function receive(item) {
      if (!item) return;
      if ((item.type === "approval" || item.type === "question") && item.payload && item.payload.requestId) {
        deferred.set(item.sessionID + ":" + item.payload.requestId, item);
      }
      if (!belongsToCurrentSession(item.sessionID)) return;
      display(item);
    }
    function belongsToCurrentSession(id) {
      if (id === sessionID) return true;
      return Array.from(agentNodes.values()).some(function (row) { return row.sessionID === id; });
    }
    function sourceLabel(id) {
      if (id === sessionID) return "主智能体";
      var row = Array.from(agentNodes.values()).find(function (candidate) { return candidate.sessionID === id; });
      return row ? row.label.textContent : "子智能体";
    }
    function replacePending(items) {
      var pendingKeys = new Set();
      S.safeArray(items).forEach(function (item) {
        if (item && item.payload && item.payload.requestId) pendingKeys.add(item.sessionID + ":" + item.payload.requestId);
        receive(item);
      });
      deferred.forEach(function (item, key) {
        if (pendingKeys.has(key)) return;
        deferred.delete(key);
        var holder = requests.get(item.payload.requestId);
        if (holder) holder.remove();
        requests.delete(item.payload.requestId);
        delete questionDrafts[draftKey(item.sessionID, item.payload.requestId)]; saveQuestions();
      });
    }
    function display(item) {
      if (item.type === "approval") approval(item.payload || {}, item.sessionID);
      if (item.type === "question") question(item.payload || {}, item.sessionID);
      if (/subagent/.test(item.type || "")) refresh();
      if (item.sessionID !== sessionID && (item.type !== "assistant-stream" || item.payload && item.payload.type === "end")) {
        var child = Array.from(agentNodes.values()).find(function (row) { return row.sessionID === item.sessionID; });
        if (child && child.root.open) loadAgent(child);
      }
    }
    function refresh() {
      if (!sessionID) return Promise.resolve();
      var id = sessionID;
      var list = T.read("subagents.list:" + id, function () {
        if (id !== sessionID) return Promise.resolve();
        var request = ++listGeneration;
        return T.call("subagents.list", { sessionId: id }).then(function (value) {
          if (id !== sessionID || request !== listGeneration) return;
          renderAgents(S.safeArray(value && value.items));
        });
      }).catch(error);
      return Promise.all([list, bridge.refresh()]);
    }
    function setActive(value) {
      if (active === value) return;
      active = value; activeGeneration++;
      if (timer) { global.clearTimeout(timer); timer = null; }
      if (active) { refresh(); resumeChildOperations(); schedule(activeGeneration); }
      else { childTimers.forEach(function (childTimer) { global.clearTimeout(childTimer); }); childTimers.clear(); }
    }
    function resumeChildOperations() {
      Object.values(childDrafts).forEach(function (state) {
        if (state.parent !== sessionID) return;
        if (state.sendID) reconcileChild(state.parent, state.childID, "send", state.sendID, 0, 0);
        if (state.stopID && !state.stopAccepted) reconcileChild(state.parent, state.childID, "stop", state.stopID, 0, 0);
      });
    }
    function schedule(token) {
      if (!active || token !== activeGeneration) return;
      timer = global.setTimeout(function () {
        timer = null;
        refresh().finally(function () { schedule(token); });
      }, 15000);
    }
    function renderAgents(items) {
      var visible = new Set();
      items.forEach(function (item) {
        var id = item.childId || item.id || item.sessionId;
        if (!id) return;
        visible.add(id);
        var row = agentNodes.get(id);
        if (!row) { row = createAgent(id); agentNodes.set(id, row); subagents.appendChild(row.root); }
        row.label.textContent = item.label || item.name || item.title || item.provider || id;
        var previousStatus = row.status.textContent;
        row.status.textContent = ({ running: "运行中", idle: "已创建", completed: "已完成", failed: "失败" })[item.status]
          || item.status || (item.running ? "运行中" : "已创建");
        row.mode = item.mode || "native";
        row.sessionID = item.sessionId || null;
        var state = childState(sessionID, id);
        if (state.stopID && state.stopAccepted && ["idle", "completed", "failed", "stopped", "cancelled"].includes(item.status)) {
          delete state.stopID; delete state.stopAccepted; state.feedback = "已停止。"; saveChildren();
        }
        if (state.stopID) row.status.textContent = "正在停止…";
        row.syncControls();
        deferred.forEach(function (pending) { if (pending.sessionID === row.sessionID) display(pending); });
        if (row.root.open && previousStatus !== row.status.textContent) loadAgent(row);
      });
      agentNodes.forEach(function (row, id) {
        if (!visible.has(id)) { row.history.dispose(); row.root.remove(); agentNodes.delete(id); }
      });
      subagents.hidden = !visible.size;
    }
    function createAgent(id) {
      var row = S.node("details", "dsh-embedded-agent"), summary = S.node("summary");
      var label = S.node("span"), status = S.node("span", "hint");
      summary.appendChild(label); summary.appendChild(status); row.appendChild(summary);
      var history = global.CodexBridgeDesktopEmbeddedDSHConversation.create();
      var historyStatus = S.node("p", "hint");
      row.appendChild(historyStatus); row.appendChild(history.root);
      var field = S.textField("给子智能体发送消息", "", "输入补充任务"); row.appendChild(field.wrapper);
      var actions = S.node("div", "form-actions");
      var feedback = S.node("p", "hint"), parent = sessionID, state = childState(parent, id);
      feedback.setAttribute("role", "status");
      field.control.value = state.text || "";
      field.control.addEventListener("input", function () { state.text = field.control.value; state.feedback = ""; saveChildren(); });
      var send = button("发送", function () {
        var text = field.control.value;
        if (!text.trim()) return;
        state.text = text; submitChild(parent, id, "send", text);
      });
      var stop = button("停止", function () { submitChild(parent, id, "stop", ""); });
      actions.appendChild(send); actions.appendChild(stop); row.appendChild(actions); row.appendChild(feedback);
      function syncControls() {
        if (!state.sendID && field.control.value !== state.text) field.control.value = state.text || "";
        send.disabled = !!state.sendID || !!state.stopID; stop.disabled = !!state.stopID;
        field.control.readOnly = !!state.sendID || !!state.stopID;
        send.textContent = state.sendID ? "发送中…" : "发送"; stop.textContent = state.stopID ? "停止中…" : "停止";
        feedback.textContent = state.feedback || "";
      }
      var result = { id: id, root: row, label: label, status: status, history: history, historyStatus: historyStatus,
        sessionID: null, mode: "native", request: 0, syncControls: syncControls };
      syncControls();
      row.addEventListener("toggle", function () { if (row.open) loadAgent(result); });
      return result;
    }
    function loadAgent(row) {
      if (!row.sessionID && row.mode !== "external") { row.historyStatus.textContent = "过程将在子会话创建后显示。"; return; }
      var child = row.sessionID, parent = sessionID;
      var action = row.mode === "external" ? "subagents.history" : "session.history";
      var payload = row.mode === "external" ? { sessionId: parent, childId: row.id } : { sessionId: child };
      T.read("subagent.history:" + JSON.stringify([parent, row.id, action, child]), function () {
        if (sessionID !== parent || row.sessionID !== child) return Promise.resolve();
        var request = ++row.request;
        return T.call(action, payload).then(function (value) {
          if (sessionID !== parent || row.sessionID !== child || row.request !== request) return;
          row.historyStatus.textContent = "";
          if (row.mode === "external") row.history.updateBridge(row.id, S.safeArray(value && value.messages));
          else row.history.update(child, "", S.safeArray(value && value.records), "", null);
        });
      }).catch(function (failure) {
        if (sessionID === parent && row.sessionID === child) row.historyStatus.textContent = failure.message || "无法读取子会话。";
      });
    }
    return { setSession: setSession, setActive: setActive, receive: receive, replacePending: replacePending, refresh: refresh };
  }
  global.CodexBridgeDesktopEmbeddedDSHInteractions = { create: create };
}(window));
