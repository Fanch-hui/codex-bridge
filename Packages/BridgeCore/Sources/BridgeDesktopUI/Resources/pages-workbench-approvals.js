(function (global) {
  "use strict";
  var S = global.CodexBridgeDesktopPageSupport;
  var N = global.CodexBridgeDesktopNativePermissions;

  function render(page, emit) {
    var container = document.getElementById("workbench-inspector-approvals");
    var approvals = page.approvals || [];
    var drafts = container.__userInputDrafts || (container.__userInputDrafts = Object.create(null));
    var activeIDs = Object.create(null);
    approvals.forEach(function (approval) { activeIDs[approval.approvalID] = true; });
    Object.keys(drafts).forEach(function (approvalID) {
      if (!activeIDs[approvalID]) delete drafts[approvalID];
    });
    global.CodexBridgeDesktopStableRender(container, JSON.stringify(page.approvals || []), function () {
    S.clear(container);
    if (approvals.length === 0) return;
    var section = S.node("div", "approvals-tray");
    approvals.forEach(function (appr) {
      var questions = S.safeArray(appr.questions);
      var isUserInput = appr.kind === "user_input" || questions.length > 0;
      var card = S.node("article", "approval-card" + (isUserInput ? " approval-user-input" : ""));
      card.appendChild(S.node("h4", null, appr.title || appr.kind));
      var body = S.node("div", "approval-body");
      card.appendChild(body);
      body.appendChild(S.node("p", null, appr.summary));
      if (isUserInput) {
        renderUserInput(body, appr, questions, drafts, emit);
      } else {
        if (appr.displayCommand) body.appendChild(S.node("pre", "mono", appr.displayCommand));
        if (appr.reason) body.appendChild(S.node("p", null, appr.reason));
        if (appr.relativePaths && appr.relativePaths.length) addListBlock(body, "涉及路径", appr.relativePaths);
      }
      var actions = S.node("div", "approval-actions");
      if (isUserInput) {
        var answerButton = S.button("提交回答", null, {}, emit, "small primary",
          appr.resolving || !answersComplete(appr, questions, drafts));
        function updateAnswerButton() {
          answerButton.disabled = appr.resolving || !answersComplete(appr, questions, drafts);
        }
        body.addEventListener("input", updateAnswerButton);
        body.addEventListener("change", updateAnswerButton);
        answerButton.addEventListener("click", function () {
          if (!answersComplete(appr, questions, drafts)) return;
          answerButton.disabled = true;
          emit("resolveApproval", {
            approvalID: appr.approvalID,
            taskID: appr.taskID,
            decision: "allow",
            input: JSON.stringify(collectAnswers(appr, questions, drafts))
          });
        });
        actions.appendChild(answerButton);
        var cancelButton = S.button("取消提问", null, {}, emit, "small", appr.resolving);
        cancelButton.addEventListener("click", function () {
          emit("resolveApproval", {
            approvalID: appr.approvalID,
            taskID: appr.taskID,
            decision: "cancel"
          });
        });
        actions.appendChild(cancelButton);
        card.appendChild(actions); section.appendChild(card);
        return;
      }
      var decs = appr.decisionOptions && appr.decisionOptions.length ? appr.decisionOptions : ["allow", "deny"];
      if (appr.canDeny && !decs.some(function (d) { return d.toLowerCase() === "deny"; })) {
        decs = decs.concat(["deny"]);
      }
      decs = decs.filter(function (decision, index) { return decs.indexOf(decision) === index; });
      decs.forEach(function (dec) {
        var normalized = dec.toLowerCase(), isDeny = normalized === "deny";
        var allowed = isDeny ? appr.canDeny : appr.canAllow;
        var cmd = appr.isDirect ? "resolveDirectApproval" : "resolveApproval";
        actions.appendChild(S.button(decisionLabel(appr, dec), cmd,
          { approvalID: appr.approvalID, taskID: appr.taskID, decision: dec }, emit,
          isDeny ? "small danger" : "small primary", appr.resolving || !allowed));
      });
      var oneTimeButton = N && N.oneTimeApprovalButton(appr, emit);
      if (oneTimeButton) actions.appendChild(oneTimeButton);
      card.appendChild(actions); section.appendChild(card);
    });
    container.appendChild(section);
    });
  }

  function renderUserInput(body, approval, questions, drafts, emit) {
    if (!questions.length) {
      body.appendChild(S.node("p", "hint", "未收到可填写的问题。"));
      return;
    }
    var draft = drafts[approval.approvalID] || (drafts[approval.approvalID] = Object.create(null));
    questions.forEach(function (question) {
      var questionDraft = draft[question.id] || (draft[question.id] = { options: [], other: "" });
      var fieldset = document.createElement("fieldset");
      fieldset.className = "user-input-question";
      var legend = document.createElement("legend");
      legend.textContent = question.header || question.question;
      fieldset.appendChild(legend);
      fieldset.appendChild(S.node("p", "user-input-prompt", question.question));
      var inputType = question.inputType || "select";
      var isTextInput = inputType === "input" || inputType === "editor";
      var optionControls = [];
      var customInput = null;
      S.safeArray(question.options).forEach(function (option) {
        var label = S.node("label", "user-input-option");
        var control = document.createElement("input");
        control.type = question.allowsMultiple === true ? "checkbox" : "radio";
        control.name = "approval-" + approval.approvalID + "-" + question.id;
        control.value = option.label;
        control.checked = questionDraft.options.indexOf(option.label) >= 0;
        optionControls.push(control);
        control.addEventListener("change", function () {
          if (question.allowsMultiple === true) {
            questionDraft.options = questionDraft.options.filter(function (item) {
              return item !== option.label;
            });
            if (control.checked) questionDraft.options.push(option.label);
          } else if (control.checked) {
            questionDraft.options = [option.label];
            questionDraft.other = "";
            if (customInput) customInput.value = "";
          }
        });
        label.appendChild(control);
        var copy = S.node("span", "user-input-option-copy");
        copy.appendChild(S.node("span", null, option.label));
        if (option.description) {
          copy.appendChild(S.node("small", "user-input-option-description", option.description));
        }
        label.appendChild(copy);
        fieldset.appendChild(label);
      });
      if (question.isOther || isTextInput || !question.options || question.options.length === 0) {
        var useEditor = inputType === "editor" && !question.isSecret;
        var other = document.createElement(useEditor ? "textarea" : "input");
        customInput = other;
        other.className = "user-input-other";
        if (!useEditor) other.type = question.isSecret ? "password" : "text";
        other.value = questionDraft.other || "";
        other.placeholder = question.isOther && !isTextInput ? "其他回答" : "请输入回答";
        other.setAttribute("aria-label", question.header || question.question);
        if (other.tagName === "INPUT") other.autocomplete = question.isSecret ? "off" : "on";
        other.addEventListener("input", function () {
          questionDraft.other = other.value;
          if (question.allowsMultiple !== true && other.value) {
            questionDraft.options = [];
            optionControls.forEach(function (control) { control.checked = false; });
          }
        });
        fieldset.appendChild(other);
      }
      body.appendChild(fieldset);
    });
  }

  function collectAnswers(approval, questions, drafts) {
    var draft = drafts[approval.approvalID] || {};
    var answers = Object.create(null);
    questions.forEach(function (question) {
      var questionDraft = draft[question.id] || {};
      var values = S.safeArray(questionDraft.options).slice();
      if (questionDraft.other) values.push(questionDraft.other);
      if (values.some(function (value) {
        return typeof value === "string" && value.trim().length > 0;
      })) answers[question.id] = values;
    });
    return answers;
  }

  function answersComplete(approval, questions, drafts) {
    if (!questions.length) return false;
    var answers = collectAnswers(approval, questions, drafts);
    return questions.every(function (question) {
      if (question.isRequired === false) return true;
      var values = S.safeArray(answers[question.id]);
      return values.some(function (value) {
        return typeof value === "string" && value.trim().length > 0;
      });
    });
  }

  function decisionLabel(approval, decision) {
    var labels = approval.decisionLabels || {};
    if (labels[decision]) return labels[decision];
    switch (decision.toLowerCase()) {
    case "allow": return "仅本次允许";
    case "allow_for_session": return "本次会话允许";
    case "allow_similar_commands": return "允许此类命令";
    case "deny": return "拒绝";
    default: return decision;
    }
  }

  function addListBlock(c, title, values) {
    c.appendChild(S.node("h4", "subsection-title", title));
    var list = S.node("div", "activity-list");
    values.forEach(function (v) { list.appendChild(S.node("div", "path-row mono", v)); });
    c.appendChild(list);
  }

  global.CodexBridgeDesktopWorkbenchApprovals = { render: render };
}(window));
