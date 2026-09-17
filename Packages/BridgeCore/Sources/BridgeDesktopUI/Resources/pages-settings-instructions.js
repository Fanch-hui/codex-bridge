(function (global) {
  "use strict";
  var S = global.CodexBridgeDesktopPageSupport;
  var D = global.CodexBridgeDesktopFormDraft;

  function create(page, emit) {
    var context = { page: page, emit: emit };
    var card = S.node("section", "page-card settings-card");
    card.appendChild(S.node("h3", null, "全局自定义指令"));
    var field = S.node("div", "field");
    field.appendChild(S.node("label", null, "发送给 Provider 的全局指令"));
    var text = S.node("textarea");
    text.value = page.customInstructions || "";
    text.placeholder = "可选。保存后由本机 Service 应用。";
    field.appendChild(text);
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
