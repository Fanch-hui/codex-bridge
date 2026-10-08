(function (global) {
  "use strict";
  var S = global.CodexBridgeDesktopPageSupport;
  function select(label) {
    var field = S.selectField(label, "", [], function () {}, "dsh-composer-choice");
    field.wrapper.querySelector("label").hidden = true;
    field.control.setAttribute("aria-label", label);
    return field;
  }
  function create() {
    var root = S.node("div", "dsh-native-composer dsh-new-session-composer");
    var row = S.node("div", "dsh-composer-input-row");
    var input = S.textAreaField("DSH 会话输入", "", "随心输入", "dsh-composer-input");
    input.control.id = "dsh-new-session-input";
    input.control.classList.add("workbench-message-input");
    input.control.setAttribute("aria-label", "DSH 会话输入");
    input.wrapper.querySelector("label").htmlFor = input.control.id;
    input.wrapper.querySelector("label").hidden = true;
    var send = S.button("发送", null, {}, null, "small primary dsh-composer-send");
    row.appendChild(input.wrapper); row.appendChild(send); root.appendChild(row);
    var toolbar = S.node("div", "dsh-composer-toolbar");
    var attachments = S.node("div", "dsh-composer-attachments"); toolbar.appendChild(attachments);
    var model = select("DSH 会话模型"), effort = select("DSH 会话推理强度"), mode = select("发送方式");
    model.wrapper.classList.add("dsh-composer-model");
    toolbar.appendChild(model.wrapper); toolbar.appendChild(effort.wrapper); toolbar.appendChild(mode.wrapper);
    var stop = S.button("停止", null, {}, null, "small dsh-composer-stop"); toolbar.appendChild(stop);
    root.appendChild(toolbar);
    var recovery = S.node("div", "dsh-composer-recovery");
    var recover = S.button("恢复提交", null, {}, null, "small");
    var edit = S.button("编辑消息", null, {}, null, "small");
    recovery.appendChild(recover); recovery.appendChild(edit); root.appendChild(recovery);
    var hint = S.node("p", "hint dsh-composer-hint"); hint.setAttribute("role", "status"); root.appendChild(hint);
    return { root: root, input: input.control, send: send,
      model: model.control, effort: effort.control, effortWrapper: effort.wrapper,
      mode: mode.control, modeWrapper: mode.wrapper,
      stop: stop, attachmentSlot: attachments, recover: recover, edit: edit, recovery: recovery, hint: hint };
  }
  function attachments(slot, draft, allowed, onChange) {
    S.clear(slot);
    var api = global.CodexBridgeDesktopWorkbenchAttachments;
    if (!api) return null;
    var view = api.create({ providerID: "deepseek-harness", canAttachImages: allowed }, draft, onChange,
      "attachmentPaths", "+");
    if (!view) return null;
    var choose = view.wrapper.querySelector("button"), explanation = view.wrapper.querySelector("p");
    if (allowed && choose) {
      choose.setAttribute("aria-label", "添加项目图片");
      choose.title = "选择项目根目录中的 PNG、JPEG 或 WebP 图片";
    }
    var update = view.update;
    view.update = function () { update(); if (explanation) explanation.hidden = true; };
    var disable = view.setDisabled;
    view.setDisabled = function (value) { disable(value); if (explanation) explanation.hidden = true; };
    view.update(); slot.appendChild(view.wrapper);
    return view;
  }
  global.CodexBridgeDesktopDSHComposerView = { create: create, attachments: attachments };
}(window));
