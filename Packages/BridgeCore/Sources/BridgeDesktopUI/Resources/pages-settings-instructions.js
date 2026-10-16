(function (global) {
  "use strict";
  var S = global.CodexBridgeDesktopPageSupport;
  var D = global.CodexBridgeDesktopFormDraft;

  function create(page, emit) {
    var context = { page: page, emit: emit };
    var card = S.node("section", "settings-subsection settings-instructions");
    var editor = S.textAreaField("给 ChatGPT / Qwen / Gemini 的指令",
      page.customInstructions || "", "可选。保存后由本机 Service 应用。");
    var field = editor.wrapper, text = editor.control;
    field.appendChild(S.node("p", "hint", "用于指导客户端理解和处理请求；Agent 任务只包含你交代的具体工作。"));
    var counter = S.node("div", "hint");
    field.appendChild(counter);
    card.appendChild(field);
    var draft = D.bind({ text: text });
    var actions = S.node("div", "form-actions");
    var save = S.button("保存指令", null, {}, emit, "small primary", !page.canSaveInstructions);
    function validate() {
      var bytes = new TextEncoder().encode(text.value).length;
      var valid = text.value.indexOf("\u0000") < 0 && bytes <= 32768;
      counter.textContent = bytes + " / 32768 字节" + (valid ? "" : " · 内容过长或包含 NUL 字符");
      counter.hidden = valid && bytes < 24576;
      save.disabled = !context.page.canSaveInstructions || !valid;
    }
    text.addEventListener("input", validate);
    text.addEventListener("compositionend", validate);
    save.addEventListener("click", function () {
      if (!save.disabled) context.emit("saveCustomInstructions", { value: text.value });
    });
    actions.appendChild(save);
    card.appendChild(actions);
    function update(next, nextEmit) {
      context.page = next;
      context.emit = nextEmit;
      draft.update({ text: next.customInstructions || "" });
      validate();
    }
    update(page, emit);
    return { root: card, update: update };
  }
  global.CodexBridgeDesktopSettingsInstructions = { create: create };
}(window));
