(function (global) {
  "use strict";
  var S = global.CodexBridgeDesktopPageSupport;
  function select(label) {
    var field = S.selectField(label, "", [], function () {}, "dsh-composer-choice");
    field.wrapper.querySelector("label").hidden = true;
    field.control.setAttribute("aria-label", label);
    return field;
  }
  function localizeEfforts(choices) {
    var names = { off: "服务默认", minimal: "极低", low: "低", medium: "中", high: "高", xhigh: "极高", max: "最大" };
    return choices.map(function (choice) {
      var id = String(choice.id || "").toLowerCase();
      var title = String(choice.title || "").trim();
      return Object.hasOwn(names, id) && (!title || title.toLowerCase() === id) ? { ...choice, title: names[id] } : choice;
    });
  }
  function create(options) {
    var root = S.node("div", "message-composer dsh-native-composer dsh-new-session-composer");
    var surface = S.node("div", "message-composer-surface"); root.appendChild(surface);
    var row = S.node("div", "message-composer-input-row");
    var input = S.textAreaField("对话输入", "", "输入消息…", "message-composer-input");
    input.control.id = "dsh-new-session-input";
    input.control.classList.add("workbench-message-input");
    input.control.setAttribute("aria-label", "对话输入");
    input.wrapper.querySelector("label").htmlFor = input.control.id;
    input.wrapper.querySelector("label").hidden = true;
    var send = S.button("", null, {}, null, "small primary message-composer-send dsh-composer-send");
    send.setAttribute("aria-label", "发送消息"); send.title = "发送消息（Enter）";
    var sendSymbol = S.node("span", null, "↑"); sendSymbol.setAttribute("aria-hidden", "true"); send.appendChild(sendSymbol);
    row.appendChild(input.wrapper); surface.appendChild(row);
    var toolbar = S.node("div", "message-composer-toolbar");
    var leading = S.node("div", "message-composer-tools dsh-composer-leading");
    var trailing = S.node("div", "message-composer-tools dsh-composer-trailing");
    var attachments = S.node("div", "dsh-composer-attachments"); leading.appendChild(attachments);
    var attachmentList = S.node("div", "dsh-composer-attachment-list"); attachmentList.hidden = true;
    surface.appendChild(attachmentList);
    var permission = select("权限"), model = select("对话模型");
    var effort = select("对话推理强度"), mode = select("发送方式");
    permission.wrapper.hidden = true;
    model.wrapper.classList.add("dsh-composer-model");
    leading.appendChild(permission.wrapper);
    var queueSlot = S.node("div", "dsh-composer-queue-slot");
    trailing.appendChild(queueSlot); trailing.appendChild(mode.wrapper); trailing.appendChild(model.wrapper); trailing.appendChild(effort.wrapper);
    toolbar.appendChild(leading); toolbar.appendChild(trailing); toolbar.appendChild(send); surface.appendChild(toolbar);
    var recovery = S.node("div", "message-composer-recovery");
    var recover = S.button("恢复提交", null, {}, null, "small");
    var edit = S.button("编辑消息", null, {}, null, "small");
    recovery.appendChild(recover); recovery.appendChild(edit);
    var hint = S.node("p", "hint message-composer-hint"); hint.setAttribute("role", "status");
    var feedback = null, detailButton = null, detailText = null, detailDialog = null;
    function updateDetailAvailability() {
      if (!detailButton || detailButton.hidden) return;
      var clipped = hint.scrollWidth > hint.clientWidth + 1;
      detailButton.style.visibility = clipped ? "visible" : "hidden";
      detailButton.tabIndex = clipped ? 0 : -1;
      detailButton.setAttribute("aria-hidden", String(!clipped));
    }
    function setHint(value) {
      value = value || "";
      if (hint.textContent === value && hint.hidden === !value) return;
      hint.textContent = value; hint.hidden = !value;
      if (!detailButton) return;
      detailButton.hidden = !value;
      if (value && global.ResizeObserver && global.requestAnimationFrame) global.requestAnimationFrame(updateDetailAvailability);
      else if (value) { detailButton.style.visibility = "visible"; detailButton.tabIndex = 0; detailButton.removeAttribute("aria-hidden"); }
    }
    if (options && options.detachedFeedback) {
      feedback = S.node("div", "dsh-composer-feedback"); feedback.hidden = true;
      feedback.appendChild(recovery); feedback.appendChild(hint);
      detailButton = S.button("⋯", null, {}, null, "small dsh-composer-feedback-detail");
      detailButton.title = "查看完整状态"; detailButton.setAttribute("aria-label", "查看完整状态");
      detailButton.hidden = true; feedback.appendChild(detailButton);
      detailDialog = S.node("dialog", "component-dialog dsh-composer-feedback-dialog");
      detailDialog.setAttribute("aria-label", "状态详情");
      var detailHeader = S.node("div", "dialog-header"); detailHeader.appendChild(S.node("h2", null, "状态详情"));
      var detailBody = S.node("div", "dialog-body"); detailText = S.node("p", "dsh-composer-feedback-text"); detailBody.appendChild(detailText);
      var detailFooter = S.node("div", "dialog-footer"), detailClose = S.button("完成", null, {}, null, "small");
      detailFooter.appendChild(detailClose); detailDialog.append(detailHeader, detailBody, detailFooter); root.appendChild(detailDialog);
      detailButton.addEventListener("click", function () {
        detailText.textContent = hint.textContent;
        if (!detailDialog.open) detailDialog.showModal();
      });
      detailClose.addEventListener("click", function () { detailDialog.close(); });
      if (global.ResizeObserver) new global.ResizeObserver(updateDetailAvailability).observe(hint);
      surface.insertBefore(feedback, toolbar);
    } else {
      root.appendChild(recovery); root.appendChild(hint);
    }
    return { root: root, input: input.control, send: send,
      permission: permission.control, permissionWrapper: permission.wrapper,
      model: model.control, effort: effort.control, effortWrapper: effort.wrapper,
      mode: mode.control, modeWrapper: mode.wrapper, queueSlot: queueSlot,
      attachmentSlot: attachments, attachmentList: attachmentList, feedback: feedback, recover: recover, edit: edit, recovery: recovery, hint: hint,
      setHint: setHint };
  }
  function attachments(slot, draft, allowed, onChange, options) {
    S.clear(slot);
    options = options || {};
    if (!allowed || !options.list || !global.CodexBridgeDesktopEmbeddedDSHAttachments) return null;
    S.clear(options.list);
    return global.CodexBridgeDesktopEmbeddedDSHAttachments.create({
      slot: slot, list: options.list, draft: draft, projectID: options.projectID, onChange: onChange
    });
  }
  global.CodexBridgeDesktopDSHComposerView = { create: create, attachments: attachments, localizeEfforts: localizeEfforts };
}(window));
