(function (global) {
  "use strict";
  var S = global.CodexBridgeDesktopPageSupport;
  var providerNames = { brave: "Brave Search", tavily: "Tavily", custom: "自定义" };

  function create(transport) {
    var root = S.node("div", "dsh-search-settings"), active = false, busy = false;
    var loaded = false, dirty = false, readFailed = false, configuredProvider = null, readSequence = 0;
    var configuredEndpoint = "", configuredFormat = "searxng";
    var refreshPending = false;
    var status = S.node("p", "hint"), feedback = S.node("p", "page-message");
    status.textContent = "正在读取搜索设置…";
    status.setAttribute("role", "status"); feedback.setAttribute("role", "status");
    var provider = S.selectField("搜索服务", "brave", [
      { id: "brave", title: "Brave Search" }, { id: "tavily", title: "Tavily" },
      { id: "custom", title: "自定义" }
    ], targetChanged);
    var format = S.selectField("接口格式", "searxng", [
      { id: "searxng", title: "SearXNG JSON" }, { id: "brave", title: "Brave Search 兼容" },
      { id: "tavily", title: "Tavily 兼容" }
    ], targetChanged);
    var endpoint = S.textField("搜索接口地址", "", "http://127.0.0.1:8888/search");
    endpoint.control.type = "url";
    endpoint.control.spellcheck = false;
    endpoint.control.addEventListener("input", targetChanged);
    var apiKey = S.textField("API Key", "", "输入所选服务的 API Key");
    apiKey.control.type = "password";
    apiKey.control.autocomplete = "off";
    apiKey.control.addEventListener("input", function () { dirty = true; showFeedback(""); syncControls(); });
    var actions = S.node("div", "form-actions");
    var save = S.button("验证并保存", null, null, null, "small primary");
    var remove = S.button("移除", null, null, null, "small");
    var retry = S.button("重试读取", null, null, null, "small");
    var customHint = S.node("p", "hint", "填写完整接口地址，使用 HTTPS 或本机 HTTP。SearXNG 需启用 JSON 格式。");
    var keyHint = S.node("p", "hint", "密钥可留空；SearXNG 使用 Bearer 认证。");
    root.appendChild(S.node("p", "hint", "搜索请求发送至所选服务，服务费用按其账号计费，与模型账号独立。"));
    root.appendChild(status); root.appendChild(provider.wrapper); root.appendChild(format.wrapper);
    root.appendChild(endpoint.wrapper); root.appendChild(customHint); root.appendChild(apiKey.wrapper); root.appendChild(keyHint);
    actions.appendChild(save); actions.appendChild(remove); actions.appendChild(retry);
    root.appendChild(actions); root.appendChild(feedback);

    save.addEventListener("click", function () {
      if (save.disabled) return;
      var input = { provider: provider.control.value }, key = apiKey.control.value.trim();
      if (provider.control.value === "custom") {
        input.endpoint = endpoint.control.value.trim();
        input.format = format.control.value;
      }
      if (key) input.apiKey = key;
      run("search.settings.save", input, save, "验证中…", function (result) {
        apiKey.control.value = ""; dirty = false;
        display(result); showFeedback("搜索服务已保存。");
      });
    });
    remove.addEventListener("click", function () {
      if (busy || !loaded || !configuredProvider) return;
      run("search.settings.remove", {}, remove, "移除中…", function (result) {
        apiKey.control.value = ""; dirty = false;
        display(result); showFeedback("搜索服务已移除。");
      });
    });
    retry.addEventListener("click", function () { void refresh(); });
    syncControls();

    function showFeedback(message) {
      feedback.textContent = message; feedback.hidden = !message;
    }
    function targetChanged() {
      apiKey.control.value = "";
      dirty = true; showFeedback(""); syncControls();
    }
    function syncControls() {
      var custom = provider.control.value === "custom";
      format.wrapper.hidden = endpoint.wrapper.hidden = customHint.hidden = !custom;
      keyHint.hidden = !custom;
      apiKey.control.placeholder = custom ? "可选：留空不发送密钥" : "输入所选服务的 API Key";
      provider.control.disabled = format.control.disabled = endpoint.control.disabled = apiKey.control.disabled = !loaded || busy;
      save.disabled = !loaded || busy || (custom ? !endpoint.control.value.trim() : !apiKey.control.value.trim());
      remove.hidden = !configuredProvider;
      remove.disabled = !loaded || busy;
      retry.hidden = !readFailed;
      retry.disabled = busy;
    }
    function display(result) {
      configuredProvider = result && result.provider || null;
      configuredEndpoint = configuredProvider === "custom" ? result.endpoint : "";
      configuredFormat = configuredProvider === "custom" ? result.format : "searxng";
      loaded = true; readFailed = false;
      if (!dirty) restoreConfiguration();
      status.textContent = configuredProvider ? "已配置 " + providerNames[configuredProvider] : "尚未配置搜索服务";
      syncControls();
    }
    function refresh() {
      if (busy) { refreshPending = true; return Promise.resolve(); }
      var current = ++readSequence;
      return transport.call("search.settings.get", {}).then(function (result) {
        if (current !== readSequence) return;
        display(result); if (!dirty) showFeedback("");
      }).catch(function (error) {
        if (current !== readSequence) return;
        readFailed = true;
        showFeedback(error && error.message || "读取搜索设置失败，请重试。");
        syncControls();
      });
    }
    function run(action, input, button, progress, onSuccess) {
      ++readSequence; busy = true; refreshPending = false;
      showFeedback(""); S.setButtonPending(button, true, progress);
      syncControls();
      return transport.call(action, input).then(onSuccess).catch(function (error) {
        showFeedback(error && error.message || "操作失败，请重试。");
      }).finally(function () {
        busy = false; S.setButtonPending(button, false); syncControls();
        if (refreshPending && active) { refreshPending = false; void refresh(); }
      });
    }
    function setActive(value) {
      var opening = !!value && !active;
      active = !!value;
      if (opening) void refresh();
    }
    function clearSecret() {
      apiKey.control.value = ""; dirty = false;
      if (loaded) restoreConfiguration();
      syncControls();
    }
    function restoreConfiguration() {
      provider.control.value = configuredProvider || "brave";
      endpoint.control.value = configuredEndpoint;
      format.control.value = configuredFormat;
    }
    return { root: root, setActive: setActive, clearSecret: clearSecret };
  }
  global.CodexBridgeDesktopEmbeddedDSHWebSearchSettings = { create: create };
}(window));
