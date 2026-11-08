(function (global) {
  "use strict";
  var S = global.CodexBridgeDesktopPageSupport, T = global.CodexBridgeDesktopEmbeddedDSHTransport;

  function create(container, labelFor, showError, sourceIsCurrent) {
    var sessionID = null, generation = 0, cards = new Map();
    var draftStorageKey = "codexbridge.workbench.external-question-drafts.v1", drafts = {};
    try { drafts = JSON.parse(global.localStorage.getItem(draftStorageKey) || "{}") || {}; } catch (_) {}
    function saveDrafts() { try { global.localStorage.setItem(draftStorageKey, JSON.stringify(drafts)); } catch (_) {} }
    function keyFor(approval) {
      return JSON.stringify([approval.childId, approval.taskID || "", approval.runID || "", approval.approvalID]);
    }
    function draftKey(parent, approval) { return JSON.stringify([parent, keyFor(approval)]); }
    function isCurrent(approval) { return !sourceIsCurrent || sourceIsCurrent(approval); }
    function setAvailable(card, available) {
      card.available = available;
      Array.from(card.root.querySelectorAll("button")).forEach(function (control) { control.disabled = !available || !!card.root.__pending; });
      if (!available) {
        var status = card.root.__status || S.node("p", "hint"); card.root.__status = status;
        status.setAttribute("role", "status"); status.textContent = "正在核对请求状态。";
        if (!status.parentNode) card.root.appendChild(status);
      } else if (card.root.__status && !card.root.__pending) card.root.__status.textContent = "";
    }
    function button(label, action) {
      var control = S.button(label, null, {}, null, "small"); control.addEventListener("click", action); return control;
    }
    function setSession(id) {
      if (id === sessionID) return;
      sessionID = id; generation++;
      cards.forEach(function (card) { card.root.remove(); }); cards.clear();
    }
    function refresh() {
      if (!sessionID) return Promise.resolve();
      var id = sessionID;
      return T.read("subagents.approvals:" + id, function () {
        if (id !== sessionID) return Promise.resolve();
        var request = ++generation;
        return T.call("subagents.approvals", { sessionId: id }).then(function (value) {
          if (id !== sessionID || request !== generation) return;
          var present = new Set();
          S.safeArray(value && value.approvals).forEach(function (approval) {
            if (!approval.approvalID || !approval.childId || !isCurrent(approval)) return;
            var key = keyFor(approval); present.add(key);
            if (!cards.has(key)) {
              var card = createCard(approval, id); cards.set(key, card); container.appendChild(card.root);
            }
            setAvailable(cards.get(key), true);
          });
          cards.forEach(function (card, key) {
            if (!present.has(key)) {
              card.root.remove(); cards.delete(key); delete drafts[draftKey(id, card.approval)]; saveDrafts();
            }
          });
        });
      }).catch(function (failure) {
        if (id === sessionID) { cards.forEach(function (card) { setAvailable(card, false); }); showError(failure); }
      });
    }
    function answer(approval, parent, decision, answers, holder) {
      var key = keyFor(approval), card = cards.get(key);
      if (parent !== sessionID || !card || card.root !== holder || !card.available || !isCurrent(approval) || holder.__pending) return;
      holder.__pending = true; holder.setAttribute("aria-busy", "true");
      var status = holder.__status || S.node("p", "hint"); holder.__status = status;
      status.setAttribute("role", "status"); status.textContent = answers ? "正在提交回答…" : "正在提交审批…";
      if (!status.parentNode) holder.appendChild(status);
      var controls = Array.from(holder.querySelectorAll("button")); controls.forEach(function (control) { control.disabled = true; });
      var payload = { sessionId: parent, childId: approval.childId, approvalID: approval.approvalID, decision: decision };
      if (approval.taskID) payload.taskID = approval.taskID;
      if (approval.runID) payload.runID = approval.runID;
      if (answers) payload.answers = answers;
      T.call("subagents.answer", payload).then(function () {
        holder.remove(); if (cards.get(key) === card) cards.delete(key);
        delete drafts[draftKey(parent, approval)]; saveDrafts();
        if (parent === sessionID) refresh();
      }).catch(function (failure) {
        if (parent !== sessionID || cards.get(key) !== card) return;
        holder.__pending = false; holder.removeAttribute("aria-busy");
        setAvailable(card, false);
        status.textContent = failure && failure.message || "提交失败，请重试。";
        refresh();
      });
    }
    function createCard(approval, parent) {
      var holder = S.node("section", "dsh-embedded-request");
      holder.appendChild(S.node("strong", null, "子智能体 · " + labelFor(approval.childId)));
      holder.appendChild(S.node("p", null, approval.title || approval.summary || "等待审批"));
      if (approval.title && approval.summary && approval.summary !== approval.title) holder.appendChild(S.node("p", null, approval.summary));
      if (approval.reason) holder.appendChild(S.node("p", "hint", approval.reason));
      if (approval.display_command) holder.appendChild(S.node("pre", "mono", approval.display_command));
      if (S.safeArray(approval.relative_paths).length) holder.appendChild(S.node("pre", "mono", approval.relative_paths.join("\n")));
      var questions = S.safeArray(approval.questions), actions = S.node("div", "form-actions");
      if (approval.kind === "user_input" || questions.length) {
        var fields = questions.map(function (question) { return questionField(holder, question, draftKey(parent, approval)); });
        actions.appendChild(button("提交回答", function () {
          var answers = {}, missing = false;
          fields.forEach(function (field) {
            var values = field.options.filter(function (option) { return option.checked; }).map(function (option) { return option.value; });
            if (field.custom && field.custom.value.trim()) values.push(field.custom.value.trim());
            if (!values.length && field.required) missing = true;
            if (values.length) answers[field.id] = values;
          });
          if (missing) { showError(new Error("请回答每个必填问题。")); return; }
          answer(approval, parent, "allow", answers, holder);
          fields.forEach(function (field) { if (field.custom && field.custom.type === "password") field.custom.value = ""; });
        }));
        actions.appendChild(button("取消提问", function () { answer(approval, parent, "cancel", null, holder); }));
      } else {
        var labels = { allow: "允许一次", allow_for_session: "本次会话允许", allow_similar_commands: "允许此类命令", deny: "拒绝" };
        var decisions = S.safeArray(approval.decisionOptions);
        (decisions.length ? decisions : ["allow", "deny"]).forEach(function (decision) {
          actions.appendChild(button(labels[decision] || decision, function () { answer(approval, parent, decision, null, holder); }));
        });
      }
      holder.appendChild(actions); return { root: holder, available: true, approval: approval };
    }
    function questionField(holder, question, key) {
      var group = S.node("fieldset", "user-input-question"), options = [];
      group.appendChild(S.node("legend", null, question.header || question.question || "请回答"));
      group.appendChild(S.node("p", null, question.question || ""));
      S.safeArray(question.options).forEach(function (option) {
        var label = S.node("label", "dsh-embedded-question-option"), input = S.node("input");
        input.type = question.allowsMultiple ? "checkbox" : "radio";
        input.name = "dsh-approval-" + key + "-" + question.id; input.value = option.label; options.push(input);
        label.appendChild(input); label.appendChild(S.node("span", null, option.label));
        if (option.description) label.appendChild(S.node("span", "hint", option.description));
        group.appendChild(label);
      });
      var custom = null;
      if (question.isOther || question.inputType === "input" || question.inputType === "editor" || !options.length) {
        var field = S.textField("回答", "", "请输入回答"); custom = field.control;
        if (question.isSecret) custom.type = "password";
        custom.addEventListener("input", function () {
          if (!question.allowsMultiple && custom.value) options.forEach(function (option) { option.checked = false; });
        });
        options.forEach(function (option) { option.addEventListener("change", function () {
          if (!question.allowsMultiple && option.checked) custom.value = "";
        }); });
        group.appendChild(field.wrapper);
      }
      var saved = !question.isSecret && drafts[key] && drafts[key][question.id];
      if (saved) {
        if (custom) custom.value = saved.custom || "";
        options.forEach(function (option) { option.checked = S.safeArray(saved.selected).includes(option.value); });
      }
      function saveField() {
        if (question.isSecret) return;
        var values = drafts[key] || (drafts[key] = {});
        values[question.id] = { custom: custom ? custom.value : "", selected: options.filter(function (option) {
          return option.checked;
        }).map(function (option) { return option.value; }) };
        saveDrafts();
      }
      if (custom) custom.addEventListener("input", saveField);
      options.forEach(function (option) { option.addEventListener("change", saveField); });
      holder.appendChild(group);
      return { id: question.id, options: options, custom: custom, required: question.isRequired !== false };
    }
    function syncSources() {
      cards.forEach(function (card, key) {
        if (!isCurrent(card.approval)) {
          card.root.remove(); cards.delete(key); delete drafts[draftKey(sessionID, card.approval)]; saveDrafts();
        }
      });
    }
    function invalidate() { cards.forEach(function (card) { setAvailable(card, false); }); }
    return { setSession: setSession, refresh: refresh, syncSources: syncSources, invalidate: invalidate };
  }
  global.CodexBridgeDesktopEmbeddedDSHBridge = { create: create };
}(window));
