(function (global) {
  "use strict";
  var S = global.CodexBridgeDesktopPageSupport, T = global.CodexBridgeDesktopEmbeddedDSHTransport;

  function create(interaction, subagents, showError, onSubagentsChange, openWorkspaceRecovery) {
    var requests = new Map(), deferred = new Map(), agentNodes = new Map(), sessionID = null, listGeneration = 0;
    var selectedAgentID = null;
    var listContainer = S.node("div", "dsh-embedded-agent-list");
    var detailContainer = S.node("div", "dsh-embedded-agent-detail"); detailContainer.hidden = true;
    subagents.appendChild(listContainer); subagents.appendChild(detailContainer);
    var questionDraftKey = "codexbridge.workbench.question-drafts.v1", questionDrafts = {};
    try { questionDrafts = JSON.parse(global.localStorage.getItem(questionDraftKey) || "{}") || {}; } catch (_) {}
    var childDraftKey = "codexbridge.workbench.child-drafts.v1", childDrafts = {}, childTimers = new Map();
    try { childDrafts = JSON.parse(global.localStorage.getItem(childDraftKey) || "{}") || {}; } catch (_) {}
    var active = false, timer = null, activeGeneration = 0;
    var bridge = global.CodexBridgeDesktopEmbeddedDSHBridge.create(interaction, function (id) {
      var row = agentNodes.get(id); return row ? row.label.textContent : id;
    }, showError, function (approval) {
      var row = agentNodes.get(approval.childId);
      return !!row && (!approval.taskID || approval.taskID === row.taskID)
        && (!approval.runID || approval.runID === row.runID);
    });

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
        if (kind === "send" && outcome === "accepted") {
          if (!state.sendPreserveDraft) state.text = "";
          state.feedback = state.sendPreserveDraft ? "已交给 Agent 处理冲突。"
            : state.sendDelivery === "queue" ? "已排队。" : "已发送。";
        }
        else state.feedback = outcome === "cancelled" ? "操作已停止。" : "操作失败，请重试。";
        if (kind === "send") { delete state.sendPreserveDraft; delete state.sendDelivery; }
        if (kind === "stop") { delete state.stopTaskID; delete state.stopRunID; }
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
    function submitChild(parent, id, kind, text, delivery, sendOptions) {
      var state = childState(parent, id), key = kind + "ID";
      if (state[key]) return;
      var row = parent === sessionID && agentNodes.get(id);
      var operationID = T.requestID(); state[key] = operationID; state.feedback = kind === "send" ? "正在发送…" : "正在停止…";
      if (kind === "send") { state.sendPreserveDraft = !!(sendOptions && sendOptions.preserveDraft); state.sendDelivery = delivery || ""; }
      if (kind === "stop") {
        state.stopAccepted = false; state.stopTaskID = row && row.taskID; state.stopRunID = row && row.runID;
      }
      saveChildren(); syncChild(parent, id);
      var input = { sessionId: parent, childId: id, operation: kind, requestId: operationID };
      if (row && row.taskID) input.taskID = row.taskID;
      if (row && row.runID) input.runID = row.runID;
      if (kind === "send") {
        input.text = text;
        if (delivery === "steer" || delivery === "queue") input.delivery = delivery;
        if (sendOptions && sendOptions.repairConflict === true) input.repairConflict = true;
      }
      T.call("operations.submit", { operationID: operationID, kind: "subagents.control", sessionID: parent,
        childID: id, requestID: operationID, input: input }, { timeoutMs: 10000 }).then(function (result) {
        if (!settleChild(parent, id, kind, operationID, result)) reconcileChild(parent, id, kind, operationID, 0, 10000);
      }).catch(function () { reconcileChild(parent, id, kind, operationID, 0, 0); });
    }
    function resolveRequest(id, action, payload, holder, requestSessionID) {
      if (holder.__pending) return;
      var key = draftKey(requestSessionID, id);
      if (requests.get(key) !== holder || !deferred.has(key)) return;
      holder.__pending = true;
      var status = holder.__status || S.node("p", "hint"); holder.__status = status;
      status.setAttribute("role", "status"); status.textContent = action === "question.answer" ? "正在提交回答…" : "正在提交审批…";
      if (!status.parentNode) holder.appendChild(status);
      holder.setAttribute("aria-busy", "true");
      Array.from(holder.querySelectorAll("button")).forEach(function (control) { control.disabled = true; });
      T.call(action, payload).then(function () {
        if (requests.get(key) !== holder) return;
        requests.delete(key);
        deferred.delete(key); holder.remove();
        delete questionDrafts[draftKey(requestSessionID, id)]; saveQuestions();
      }).catch(function (failure) {
        if (requests.get(key) !== holder || !deferred.has(key)) return;
        holder.__pending = false; holder.removeAttribute("aria-busy");
        Array.from(holder.querySelectorAll("button")).forEach(function (control) { control.disabled = false; });
        status.textContent = failure && failure.message || "提交失败，请重试。";
      });
    }
    function approval(value, source) {
      var id = value.requestId, key = draftKey(source, id);
      if (!id || requests.has(key)) return;
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
      holder.appendChild(actions); interaction.appendChild(holder); requests.set(key, holder);
    }
    function question(value, source) {
      var id = value.requestId, key = draftKey(source, id);
      if (!id || requests.has(key)) return;
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
      interaction.appendChild(holder); requests.set(key, holder);
    }
    function clearRequests() { requests.forEach(function (holder) { holder.remove(); }); requests.clear(); }
    function syncViewMode() {
      var selected = selectedAgentID && agentNodes.get(selectedAgentID) || null;
      if (!selected) selectedAgentID = null;
      listContainer.hidden = !!selected;
      detailContainer.hidden = !selected;
      agentNodes.forEach(function (row, id) {
        row.detail.hidden = id !== selectedAgentID;
        row.item.classList.toggle("is-active", id === selectedAgentID);
      });
    }
    function openAgent(id) {
      var row = agentNodes.get(id);
      if (!row) return;
      selectedAgentID = id;
      syncViewMode();
      loadAgent(row);
    }
    function closeAgent() {
      selectedAgentID = null;
      syncViewMode();
    }
    function setSession(id) {
      if (id === sessionID) return;
      childTimers.forEach(function (timer) { global.clearTimeout(timer); }); childTimers.clear();
      sessionID = id; selectedAgentID = null; listGeneration++; clearRequests();
      agentNodes.forEach(function (row) {
        if (row.childHistory) row.childHistory.dispose();
        row.history.dispose(); row.item.remove(); row.detail.remove();
      });
      agentNodes.clear(); S.clear(listContainer); S.clear(detailContainer);
      syncViewMode();
      subagents.hidden = true;
      if (onSubagentsChange) onSubagentsChange(0, false);
      bridge.setSession(id);
      deferred.forEach(function (item) { if (item.sessionID === id) display(item); });
      if (id && active) { refresh(); resumeChildOperations(); }
    }
    function receive(item) {
      if (!item) return;
      if ((item.type === "approval" || item.type === "question") && item.payload && item.payload.requestId) {
        deferred.set(draftKey(item.sessionID, item.payload.requestId), item);
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
        if (item && item.payload && item.payload.requestId) pendingKeys.add(draftKey(item.sessionID, item.payload.requestId));
        receive(item);
      });
      deferred.forEach(function (item, key) {
        if (pendingKeys.has(key)) return;
        deferred.delete(key);
        var holder = requests.get(key);
        if (holder) holder.remove();
        requests.delete(key);
        delete questionDrafts[draftKey(item.sessionID, item.payload.requestId)]; saveQuestions();
      });
    }
    function isNonTerminalStatus(status) {
      return ["running", "starting", "created", "queued", "waiting-for-workspace", "awaiting_local_approval", "stopping"].includes(status);
    }
    function capabilities(item) {
      if (item.capabilities && typeof item.capabilities === "object") return item.capabilities;
      if (item.mode === "external") return {};
      var running = isNonTerminalStatus(item.status);
      return { canSend: true, canSteer: running, canContinue: !running, canStop: running };
    }
    function workspaceStatus(value) {
      return { pending: "变更等待合并", merged: "变更已合入", conflict: "变更有冲突", retained: "变更保留在副本",
        failed: "变更合并失败", validation_required: "变更等待验证", validating: "正在验证变更",
        recovery_required: "变更等待恢复", merging: "正在合并变更" }[value] || "";
    }
    function hasActiveAgents() {
      return Array.from(agentNodes.values()).some(function (row) { return isNonTerminalStatus(row.rawStatus); });
    }
    function display(item) {
      if (item.type === "approval") approval(item.payload || {}, item.sessionID);
      if (item.type === "question") question(item.payload || {}, item.sessionID);
      if (/subagent/.test(item.type || "") || item.sessionID === sessionID && ["tool/call", "tool/result", "user/message", "turn/end", "status"].includes(item.type)) {
        refresh();
      }
      if (item.sessionID !== sessionID) {
        var child = Array.from(agentNodes.values()).find(function (row) { return row.sessionID === item.sessionID; });
        if (child && selectedAgentID === child.id) {
          if (child.mode !== "external" && child.childHistory) child.childHistory.receive(item);
          else if (item.type !== "assistant-stream" || item.payload && item.payload.type === "end") loadAgent(child);
        }
      }
    }
    function refresh() {
      if (!sessionID) return Promise.resolve();
      var id = sessionID;
      return T.read("subagents.list:" + id, function () {
        if (id !== sessionID) return Promise.resolve();
        var request = ++listGeneration;
        return T.call("subagents.list", { sessionId: id }).then(function (value) {
          if (id !== sessionID || request !== listGeneration) return;
          renderAgents(S.safeArray(value && value.items));
        });
      }).then(function () { if (id === sessionID) return bridge.refresh(); }).catch(function (failure) {
        if (id === sessionID) {
          if (bridge.invalidate) bridge.invalidate();
          agentNodes.forEach(function (row) { row.invalidateControls(); });
          error(failure);
        }
      });
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
      if (timer) { global.clearTimeout(timer); timer = null; }
      var delay = hasActiveAgents() ? 2000 : 15000;
      timer = global.setTimeout(function () {
        timer = null;
        refresh().finally(function () { schedule(token); });
      }, delay);
    }
    function renderAgents(items) {
      var visible = new Set(), added = false, wasActive = hasActiveAgents();
      var statusLabels = {
        running: "运行中",
        starting: "启动中",
        created: "启动中",
        queued: "排队中",
        "waiting-for-workspace": "等待写入",
        unknown: "待核对",
        awaiting_local_approval: "等待批准",
        idle: "",
        inactive: "已完成",
        completed: "已完成",
        failed: "失败",
        interrupted: "已停止",
        stopped: "已停止",
        cancelled: "已停止"
      };
      items.forEach(function (item) {
        var id = item.childId || item.id || item.sessionId;
        if (!id) return;
        visible.add(id);
        var row = agentNodes.get(id);
        if (!row) {
          row = createAgent(id);
          agentNodes.set(id, row);
          listContainer.appendChild(row.item);
          detailContainer.appendChild(row.detail);
          added = true;
        }
        var titleText = item.label || item.name || item.title || item.provider || id;
        row.label.textContent = titleText;
        row.detailLabel.textContent = titleText;
        var previousStatus = row.rawStatus;
        row.rawStatus = item.status || (item.running ? "running" : "");
        var bindingChanged = row.mode !== (item.mode || "native") || row.sessionID !== (item.sessionId || null)
          || row.taskID !== (item.taskID || null) || row.runID !== (item.runID || null);
        if (bindingChanged) {
          row.loadedOnce = false;
          if (row.childHistory) { row.childHistory.dispose(); row.childHistory = null; }
        }
        row.mode = item.mode || "native"; row.sessionID = item.sessionId || null;
        row.taskID = item.taskID || null; row.runID = item.runID || null; row.capabilities = capabilities(item);
        var statusText = statusLabels[item.status] !== undefined
          ? statusLabels[item.status]
          : ((item.status === "idle" ? "" : item.status) || (item.running ? "运行中" : ""));
        var mode = item.admission === "waiting" || item.status === "waiting-for-workspace" ? "等待写入"
          : item.workspaceMode === "isolated" ? "独立副本执行"
          : item.workspaceMode === "shared" || item.mode === "native" ? "共享目录执行" : "";
        var summary = [statusText, mode === statusText ? "" : mode, workspaceStatus(item.workspaceStatus)].filter(Boolean).join(" · ");
        row.status.textContent = summary;
        row.detailStatus.textContent = summary;
        row.workspaceReason.textContent = item.workspaceReason || item.failureReason || "";
        row.workspaceReason.hidden = !row.workspaceReason.textContent;
        row.renderWorkspace(item);
        var state = childState(sessionID, id);
        var stoppedRunChanged = state.stopTaskID && row.taskID && state.stopTaskID !== row.taskID
          || state.stopRunID && row.runID && state.stopRunID !== row.runID;
        if (state.stopID && state.stopAccepted && (stoppedRunChanged
          || ["idle", "inactive", "completed", "failed", "interrupted", "stopped", "cancelled"].includes(item.status))) {
          delete state.stopID; delete state.stopAccepted; delete state.stopTaskID; delete state.stopRunID;
          state.feedback = !stoppedRunChanged && ["interrupted", "stopped", "cancelled"].includes(item.status) ? "已停止。" : "任务已结束。";
          saveChildren();
        }
        if (state.stopID) {
          row.status.textContent = ["正在停止…", mode, workspaceStatus(item.workspaceStatus)].filter(Boolean).join(" · ");
          row.detailStatus.textContent = row.status.textContent;
        }
        row.status.title = row.status.textContent; row.detailStatus.title = row.detailStatus.textContent;
        row.syncControls();
        deferred.forEach(function (pending) { if (pending.sessionID === row.sessionID) display(pending); });
        if (selectedAgentID === id && (bindingChanged || previousStatus !== row.rawStatus || isNonTerminalStatus(row.rawStatus))) loadAgent(row);
      });
      agentNodes.forEach(function (row, id) {
        if (!visible.has(id)) {
          if (row.childHistory) row.childHistory.dispose();
          row.history.dispose();
          row.item.remove();
          row.detail.remove();
          agentNodes.delete(id);
        }
      });
      syncViewMode();
      if (bridge.syncSources) bridge.syncSources();
      subagents.hidden = !visible.size;
      if (active && wasActive !== hasActiveAgents()) schedule(activeGeneration);
      if (onSubagentsChange) onSubagentsChange(visible.size, added);
    }
    function createAgent(id) {
      var parent = sessionID;
      return global.CodexBridgeDesktopEmbeddedDSHChildView.create({
        id: id, state: childState(parent, id),
        isCurrent: function (row) { return parent === sessionID && agentNodes.get(id) === row; },
        open: function () { openAgent(id); }, close: closeAgent, save: saveChildren,
        openRecovery: openWorkspaceRecovery,
        submit: function (kind, text, delivery, sendOptions) {
          submitChild(parent, id, kind, text, delivery, sendOptions);
        }
      });
    }
    function loadAgent(row) {
      if (row.mode === "external") {
        // The task is created after the child appears (workspace reservation, dispatch).
        if (!row.taskID) {
          row.historyStatus.textContent = "过程将在子 Agent 启动后显示。";
          row.historyStatus.hidden = false;
          return;
        }
        var bindingKey = JSON.stringify([row.taskID, row.runID || null]);
        if (row.childHistory && row.childHistoryKey !== bindingKey) {
          row.childHistory = null; row.loadedOnce = false;
        }
        if (!row.childHistory) {
          row.childHistoryKey = bindingKey;
          var binding = { parent: sessionID, child: row.id, taskID: row.taskID, runID: row.runID };
          row.childHistory = global.CodexBridgeDesktopEmbeddedDSHChildHistory.create({
            isCurrent: function (value) {
              return sessionID === value.parent && agentNodes.get(row.id) === row && row.mode === "external"
                && row.taskID === value.taskID && row.runID === value.runID;
            },
            onChange: function (snapshot) {
              row.loadedOnce = snapshot.loaded;
              row.history.updateBridge(row.id, snapshot.messages, { hasMore: snapshot.hasMore,
                loadingEarlier: snapshot.loadingEarlier, running: isNonTerminalStatus(row.rawStatus),
                onLoadEarlier: function () { row.childHistory.loadEarlier(); } });
              row.historyStatus.textContent = snapshot.loaded && !snapshot.messages.length ? "暂无会话内容。" : "";
              row.historyStatus.hidden = !row.historyStatus.textContent;
            },
            onError: function (failure) {
              row.historyStatus.textContent = failure && failure.message || "无法读取子会话。";
              row.historyStatus.hidden = false;
            }
          });
          row.childHistory.reset(binding);
        }
        if (!row.loadedOnce) { row.historyStatus.textContent = "正在加载会话内容…"; row.historyStatus.hidden = false; }
        return row.childHistory.load();
      }
      if (!row.sessionID) {
        row.historyStatus.textContent = "过程将在子会话创建后显示。";
        row.historyStatus.hidden = false;
        return;
      }
      if (!row.childHistory) {
        var nativeBinding = { parent: sessionID, child: row.id, session: row.sessionID };
        row.childHistory = global.CodexBridgeDesktopEmbeddedDSHChildHistory.createNative({
          isCurrent: function (value) {
            return sessionID === value.parent && agentNodes.get(row.id) === row && row.mode !== "external"
              && row.sessionID === value.session;
          },
          onChange: function (snapshot) {
            row.loadedOnce = true;
            row.history.update(row.sessionID, "", snapshot.records, snapshot.streamText, null, snapshot.streamReasoning,
              { hasMore: snapshot.hasMore, loadingEarlier: snapshot.loadingEarlier, streamTools: snapshot.streamTools,
                running: isNonTerminalStatus(row.rawStatus), onLoadEarlier: function () { row.childHistory.loadEarlier(); } });
            row.historyStatus.textContent = snapshot.records.length || snapshot.streamText || snapshot.streamReasoning ? "" : "暂无会话内容。";
            row.historyStatus.hidden = !row.historyStatus.textContent;
          },
          onError: function (failure) {
            row.historyStatus.textContent = failure && failure.message || "无法读取子会话。";
            row.historyStatus.hidden = false;
          }
        });
        row.childHistory.reset(nativeBinding);
      }
      if (!row.loadedOnce) {
        row.historyStatus.textContent = "正在加载会话内容…";
        row.historyStatus.hidden = false;
      }
      return row.childHistory.load();
    }
    return { setSession: setSession, setActive: setActive, receive: receive, replacePending: replacePending, refresh: refresh };
  }
  global.CodexBridgeDesktopEmbeddedDSHInteractions = { create: create };
}(window));
