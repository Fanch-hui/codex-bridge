(function (global) {
  "use strict";

  var timer = null;
  var leaveTimer = null;
  var renderedID = null;

  function node(tag, className, text) {
    var element = document.createElement(tag);
    if (className) element.className = className;
    element.textContent = text || "";
    return element;
  }

  function iconNode(symbol, className) {
    var element = node("span", "icon" + (className ? " " + className : ""));
    element.dataset.symbol = symbol;
    var icons = global.CodexBridgeDesktopIcons;
    if (icons) {
      element.innerHTML = '<svg viewBox="0 0 24 24" aria-hidden="true">'
        + (icons[symbol] || icons["info.circle"] || "") + "</svg>";
    }
    return element;
  }

  function toneClass(tone) {
    return tone || "neutral";
  }

  function symbolForTone(tone) {
    if (tone === "success") return "checkmark.circle.fill";
    if (tone === "warning") return "exclamationmark.triangle.fill";
    if (tone === "error") return "xmark.circle.fill";
    return "info.circle.fill";
  }

  function clearTimers() {
    if (timer !== null) {
      global.clearTimeout(timer);
      timer = null;
    }
    if (leaveTimer !== null) {
      global.clearTimeout(leaveTimer);
      leaveTimer = null;
    }
  }

  function clear() {
    clearTimers();
    var layer = document.getElementById("feedback-layer");
    var dialog = layer.querySelector("dialog");
    if (dialog && dialog.open) dialog.close();
    layer.innerHTML = "";
    layer.hidden = true;
  }

  function dismiss(feedback, emit, animate) {
    clearTimers();
    var layer = document.getElementById("feedback-layer");
    var toast = animate && layer ? layer.querySelector(".feedback-toast") : null;
    var reduced = global.matchMedia && global.matchMedia("(prefers-reduced-motion: reduce)").matches;
    if (toast && !reduced) {
      toast.setAttribute("data-leaving", "true");
      leaveTimer = global.setTimeout(function () {
        leaveTimer = null;
        clear();
        emit("dismissFeedback", { feedbackID: feedback.id });
      }, 170);
      return;
    }
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
    close.addEventListener("click", function () { dismiss(feedback, emit, false); });
    footer.appendChild(close);
    dialog.appendChild(footer);
    dialog.addEventListener("cancel", function (event) {
      event.preventDefault();
      dismiss(feedback, emit, false);
    });
    layer.appendChild(dialog);
    dialog.showModal();
  }

  function renderToast(layer, feedback, emit) {
    var kind = toneClass(feedback.tone);
    layer.className = "feedback-layer is-toast";
    var toast = node("section", "feedback-toast tone-" + kind);
    toast.setAttribute("role", kind === "error" ? "alert" : "status");

    toast.appendChild(iconNode(symbolForTone(kind), "feedback-toast-icon"));

    var copy = node("div", "feedback-toast-copy");
    if (feedback.title) copy.appendChild(node("strong", null, feedback.title));
    if (feedback.message) copy.appendChild(node("span", null, feedback.message));
    toast.appendChild(copy);

    var close = node("button", "feedback-dismiss");
    close.type = "button";
    close.setAttribute("aria-label", "关闭提示");
    close.appendChild(iconNode("xmark"));
    close.addEventListener("click", function () { dismiss(feedback, emit, true); });
    toast.appendChild(close);

    var baseDuration = kind === "warning" ? 10000 : kind === "error" ? 5200 : 3400;
    function scheduleDismiss(delay) {
      if (timer !== null) global.clearTimeout(timer);
      timer = global.setTimeout(function () { dismiss(feedback, emit, true); }, delay);
    }
    toast.addEventListener("mouseenter", function () {
      if (timer !== null) {
        global.clearTimeout(timer);
        timer = null;
      }
    });
    toast.addEventListener("mouseleave", function () {
      scheduleDismiss(kind === "warning" ? 4500 : 2200);
    });
    layer.appendChild(toast);
    scheduleDismiss(baseDuration);
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
