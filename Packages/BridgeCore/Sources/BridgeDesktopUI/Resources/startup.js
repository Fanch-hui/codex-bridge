(function (global) {
  "use strict";
  var root = document.getElementById("startup-screen");
  var shell = document.getElementById("app-shell");
  var status = document.getElementById("startup-status");
  var actions = document.getElementById("startup-actions");
  var retry = document.getElementById("startup-retry");
  var enter = document.getElementById("startup-enter");
  var finished = document.documentElement.dataset.surface === "preferences";
  var retryAction = null, slowTimer = null, exitTimer = null;

  function reveal() {
    root.hidden = true;
    if (exitTimer != null) global.clearTimeout(exitTimer);
    exitTimer = null;
  }
  function finish() {
    if (finished) return;
    finished = true;
    global.clearTimeout(slowTimer);
    retryAction = null;
    shell.inert = false;
    root.setAttribute("aria-busy", "false");
    root.dataset.state = "leaving";
    if (root.contains(document.activeElement)) document.activeElement.blur();
    exitTimer = global.setTimeout(reveal, 180);
  }
  function wait() {
    global.clearTimeout(slowTimer);
    root.dataset.state = "loading";
    root.setAttribute("aria-busy", "true");
    status.textContent = "正在打开工作台…";
    actions.hidden = true;
    slowTimer = global.setTimeout(function () {
      root.dataset.state = "slow";
      status.textContent = "工作台仍在启动，可以先进入应用。";
      actions.hidden = false;
      retry.hidden = !retryAction;
    }, 30000);
  }
  function update(value) {
    if (finished || !value) return;
    if (value.status === "ready") { finish(); return; }
    retryAction = typeof value.retry === "function" ? value.retry : null;
    retry.hidden = !retryAction;
    if (value.status === "error") {
      global.clearTimeout(slowTimer);
      root.dataset.state = "error";
      root.setAttribute("aria-busy", "false");
      status.textContent = value.message || "工作台启动失败，请重试。";
      actions.hidden = false;
    } else if (root.dataset.state === "error") wait();
  }
  retry.addEventListener("click", function () {
    if (!retryAction || finished) return;
    var action = retryAction;
    wait();
    Promise.resolve().then(action).catch(function () {
      update({ status: "error", message: "工作台启动失败，请重试。", retry: action });
    });
  });
  enter.addEventListener("click", finish);
  root.addEventListener("transitionend", function (event) { if (event.target === root && finished) reveal(); });
  if (finished) root.hidden = true;
  else { shell.inert = true; wait(); }
  global.CodexBridgeDesktopStartup = { update: update };
}(window));
