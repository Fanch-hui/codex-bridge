(function (global) {
  "use strict";

  var timer = null;
  var renderedID = null;

  function node(tag, className, text) {
    var element = document.createElement(tag);
    if (className) element.className = className;
    element.textContent = text || "";
    return element;
  }

  function toneClass(tone) {
    return tone || "neutral";
  }

  function clear() {
    if (timer !== null) {
      global.clearTimeout(timer);
      timer = null;
    }
    var layer = document.getElementById("feedback-layer");
    var dialog = layer.querySelector("dialog");
    if (dialog && dialog.open) dialog.close();
    layer.innerHTML = "";
    layer.hidden = true;
  }

  function dismiss(feedback, emit) {
    clear();
    emit("dismissFeedback", { feedbackID: feedback.id });
  }

  function renderDialog(layer, feedback, emit) {
    layer.className = "feedback-layer is-alert";
    var dialog = node("dialog", "component-dialog feedback-dialog tone-" + toneClass(feedback.tone));
    dialog.setAttribute("role", "alertdialog");
    dialog.setAttribute("aria-modal", "true");
    dialog.setAttribute("aria-labelledby", "feedback-title");
    dialog.setAttribute("aria-describedby", "feedback-message");

    var header = node("header", "dialog-header");
    var title = node("h2", "feedback-title", feedback.title);
    title.id = "feedback-title";
    header.appendChild(title);
    dialog.appendChild(header);
    var body = node("div", "dialog-body");
    var message = node("p", "feedback-message", feedback.message);
    message.id = "feedback-message";
    body.appendChild(message);
    dialog.appendChild(body);

    var footer = node("footer", "dialog-footer");
    var close = node("button", "button primary", "好");
    close.type = "button";
    close.autofocus = true;
    close.addEventListener("click", function () { dismiss(feedback, emit); });
    footer.appendChild(close);
    dialog.appendChild(footer);
    dialog.addEventListener("cancel", function (event) {
      event.preventDefault();
      dismiss(feedback, emit);
    });
    layer.appendChild(dialog);
    dialog.showModal();
  }

  function renderToast(layer, feedback, emit) {
    layer.className = "feedback-layer is-toast";
    var toast = node("section", "feedback-toast tone-" + toneClass(feedback.tone));
    toast.setAttribute("role", "status");

    var copy = document.createElement("div");
    copy.appendChild(node("strong", null, feedback.title));
    copy.appendChild(node("span", null, feedback.message));
    toast.appendChild(copy);

    var close = node("button", "feedback-dismiss", "×");
    close.type = "button";
    close.setAttribute("aria-label", "关闭提示");
    close.addEventListener("click", function () { dismiss(feedback, emit); });
    toast.appendChild(close);
    layer.appendChild(toast);
    timer = global.setTimeout(function () { dismiss(feedback, emit); }, feedback.tone === "warning" ? 10000 : 3200);
  }

  function render(feedback, emit) {
    if (!feedback) {
      renderedID = null;
      clear();
      return;
    }
    if (feedback.id === renderedID) return;
    renderedID = feedback.id;
    clear();

    var layer = document.getElementById("feedback-layer");
    layer.hidden = false;
    if (feedback.kind === "alert") {
      renderDialog(layer, feedback, emit);
    } else {
      renderToast(layer, feedback, emit);
    }
  }

  global.CodexBridgeDesktopFeedback = { render: render };
}(window));
