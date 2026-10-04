(function (global) {
  "use strict";
  var S = global.CodexBridgeDesktopPageSupport;
  var runningStates = ["checking", "installing", "configuring", "verifying"];
  function running(operation) { return !!operation && runningStates.indexOf(operation.state) >= 0; }
  function create(context, providerValue, onRetry) {
    var operation = null, provider = providerValue, dismissed = null, lastAction = null, returnFocus = null;
    var root = S.node("dialog", "agent-setup-dialog");
    root.setAttribute("aria-label", "Agent 一键配置");
    var heading = S.node("h3", null, "一键配置"); root.appendChild(heading);
    var message = S.node("p"); message.setAttribute("role", "status"); root.appendChild(message);
    var location = S.node("p", "row-detail"); root.appendChild(location);
    var instructions = S.node("p", "agent-setup-instructions"); root.appendChild(instructions);
    var credentials = S.node("div", "form-grid"); root.appendChild(credentials);
    var protocol = S.selectField("推理协议", "deepseek-messages", [
      { id: "deepseek-messages", title: "DeepSeek Messages" },
      { id: "openai-completions", title: "OpenAI Chat Completions" }
    ], function () {});
    var base = S.textField("Base URL", "", "https://api.example.com");
    var catalog = S.textField("模型目录 Base URL（可选）", "", "留空时按推理协议解析");
    var key = S.textField("API key", "", "输入 API key");
    key.control.type = "password"; key.control.autocomplete = "off";
    [protocol, base, catalog, key].forEach(function (field) { credentials.appendChild(field.wrapper); });
    var candidate = S.selectField("选择已有安装", "", [], function () {}); root.appendChild(candidate.wrapper);
    var permission = S.node("p", "agent-setup-instructions",
      "AGY 无头任务需要自动通过工具执行。确认后会将本机 AGY 全局工具策略设为 Always Proceed（总是通过），这会影响使用同一配置的其他 AGY CLI 任务。");
    root.appendChild(permission);
    var actions = S.node("div", "form-actions"); root.appendChild(actions);
    var login = S.button("打开登录 / 配置", null, {}, null, "small primary", false);
    var docs = S.button("官方登录说明", null, {}, null, "small", false);
    var proceed = S.button("我已完成，重新检测", null, {}, null, "small primary", false);
    var cancel = S.button("取消配置", null, {}, null, "small", false);
    var retry = S.button("重试配置", null, {}, null, "small primary", false);
    var close = S.button("关闭", null, {}, null, "small", false);
    [login, proceed, docs, retry, cancel, close].forEach(function (button) { actions.appendChild(button); });
    function closeDialog() {
      dismissed = operation && operation.operationID;
      key.control.value = "";
      if (root.open) root.close();
      if (returnFocus && returnFocus.isConnected) returnFocus.focus();
    }
    root.addEventListener("cancel", function (event) { event.preventDefault(); closeDialog(); });
    close.addEventListener("click", closeDialog);
    retry.addEventListener("click", function () { closeDialog(); onRetry(); });
    login.addEventListener("click", function () {
      if (operation && !login.disabled) context.emit("openAgentSetupLogin", { operationID: operation.operationID });
    });
    docs.addEventListener("click", function () {
      if (operation && operation.documentationURL) context.emit("openExternalURL", { url: operation.documentationURL });
    });
    proceed.addEventListener("click", function () {
      if (!operation || proceed.disabled) return;
      var payload = { operationID: operation.operationID, confirmed: operation.userAction === "permission" };
      if (operation.userAction === "credentials") {
        payload.baseURL = base.control.value; payload.apiKey = key.control.value;
        payload.inferenceProtocol = protocol.control.value; payload.catalogBaseURL = catalog.control.value;
      }
      if (operation.userAction === "select_installation") payload.installationID = candidate.control.value;
      context.emit("continueAgentSetup", payload);
      key.control.value = "";
      proceed.disabled = true;
    });
    cancel.addEventListener("click", function () {
      if (operation) context.emit("cancelAgentSetup", { operationID: operation.operationID });
      cancel.disabled = true;
    });
    function valid() {
      if (!operation) return false;
      if (operation.userAction === "credentials") return !!base.control.value.trim()
        && (!!key.control.value.trim() || !!provider.configuredBaseURL);
      if (operation.userAction === "select_installation") return !!candidate.control.value;
      return true;
    }
    [base.control, key.control, candidate.control].forEach(function (control) {
      control.addEventListener("input", function () { proceed.disabled = running(operation) || !valid(); });
    });
    function open() {
      if (!operation || root.open) return;
      dismissed = null; returnFocus = document.activeElement;
      root.showModal(); close.focus();
    }
    function update(value, nextProvider) {
      provider = nextProvider;
      var changed = value && (!operation || operation.operationID !== value.operationID);
      operation = value;
      if (!value) { if (root.open) root.close(); return; }
      if (changed) {
        base.control.value = provider.configuredBaseURL || "";
        protocol.control.value = provider.configuredInferenceProtocol || "deepseek-messages";
        catalog.control.value = provider.configuredCatalogBaseURL || "";
        key.control.value = ""; lastAction = null;
      }
      heading.textContent = provider.displayName + " · 一键配置";
      message.textContent = value.message;
      location.textContent = [value.installationDirectory || value.executablePath, value.version].filter(Boolean).join(" · ");
      instructions.textContent = value.loginInstructions || ""; instructions.hidden = !instructions.textContent;
      var needs = value.state === "needs_user_action";
      credentials.hidden = !needs || value.userAction !== "credentials";
      candidate.wrapper.hidden = !needs || value.userAction !== "select_installation";
      permission.hidden = !needs || value.userAction !== "permission";
      var choices = S.safeArray(value.candidates);
      if (changed || lastAction !== value.userAction) {
        S.clear(candidate.control);
        choices.forEach(function (item) {
          var option = S.node("option", null, item.displayName + " · " + item.executablePath);
          option.value = item.installationID; candidate.control.appendChild(option);
        });
      }
      login.hidden = !needs || !value.canOpenLogin;
      docs.hidden = !value.documentationURL;
      login.disabled = !context.canConnect;
      proceed.hidden = !needs;
      proceed.textContent = value.userAction === "credentials" ? "保存并检测"
        : value.userAction === "permission" ? "允许并继续"
        : value.userAction === "select_installation" ? "使用此安装" : "我已完成，重新检测";
      proceed.disabled = !context.canConnect || !valid();
      retry.hidden = ["failed", "cancelled", "interrupted"].indexOf(value.state) < 0;
      retry.disabled = !context.canConnect;
      cancel.hidden = ["ready", "failed", "cancelled", "interrupted"].indexOf(value.state) >= 0;
      cancel.disabled = !context.canConnect;
      if (needs && dismissed !== value.operationID && (changed || lastAction !== value.userAction)) open();
      lastAction = value.userAction;
    }
    return { root: root, update: update, open: open, operation: function () { return operation; } };
  }
  global.CodexBridgeDesktopAgentSetup = { create: create, running: running };
}(window));
