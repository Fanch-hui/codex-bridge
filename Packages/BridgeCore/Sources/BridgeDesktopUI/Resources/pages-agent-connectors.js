(function (global) {
  "use strict";
  var S = global.CodexBridgeDesktopPageSupport;
  var D = global.CodexBridgeDesktopFormDraft;

  function create(emit) {
    var context = { emit: emit, enabled: false };
    var root = S.node("div", "agent-connectors");
    var rows = new Map();
    var empty = S.node("div", "list-empty", "暂无可自动连接的 Agent Provider。");
    root.appendChild(empty);

    function createRow(provider) {
      var row = S.node("div", "agent-connect-row");
      var main = S.node("div", "row-main");
      var heading = S.node("div", "client-heading");
      var title = S.node("div", "row-title", provider.displayName);
      var status = S.badge("未连接", "neutral");
      heading.appendChild(title);
      heading.appendChild(status);
      main.appendChild(heading);
      var detail = S.node("div", "row-detail");
      main.appendChild(detail);
      row.appendChild(main);

      var controls = S.node("div", "agent-connect-controls");
      var fields = S.node("div", "form-grid agent-connect-fields");
      var baseURL = S.textField("Base URL", "", "https://api.example.com");
      var apiKey = S.textField("API key", "", "输入 API key");
      apiKey.control.type = "password";
      apiKey.control.autocomplete = "off";
      fields.appendChild(baseURL.wrapper);
      fields.appendChild(apiKey.wrapper);
      controls.appendChild(fields);
      var action = S.button("一键连接", null, {}, null, "small primary", true);
      controls.appendChild(action);
      row.appendChild(controls);
      var hint = S.node("div", "form-guide-note");
      controls.appendChild(hint);

      var draft = D.bind({ baseURL: baseURL.control, apiKey: apiKey.control });
      var currentProvider = provider;
      var currentInstallation = null;
      function hasValue(value) {
        return !!value && value.trim().length > 0;
      }
      function validate() {
        var hasBaseURL = hasValue(baseURL.control.value);
        var hasAPIKey = hasValue(apiKey.control.value);
        var hasAnyConfiguration = hasBaseURL || hasAPIKey;
        var hasCompleteConfiguration = hasBaseURL && hasAPIKey;
        var requiresConfiguration = currentProvider.requiresConfiguration
          && ((!currentInstallation && !hasCompleteConfiguration)
            || (hasAnyConfiguration && !hasCompleteConfiguration));
        action.disabled = !context.enabled || requiresConfiguration;
      }
      function label(installation) {
        if (!installation) return "未连接";
        if (installation.availability === "available" && installation.isEnabled) return "已连接";
        if (installation.availability === "available") return "已发现";
        if (installation.availability === "needs_review") return "需复核";
        if (installation.availability === "unavailable") return "不可用";
        return "未知";
      }
      function tone(installation) {
        if (!installation) return "neutral";
        if (installation.availability === "available" && installation.isEnabled) return "success";
        if (installation.availability === "available") return "warning";
        if (installation.availability === "needs_review") return "warning";
        if (installation.availability === "unavailable") return "error";
        return "neutral";
      }
      function update(nextProvider, installation, nextEmit) {
        currentProvider = nextProvider;
        currentInstallation = installation;
        context.emit = nextEmit;
        title.textContent = nextProvider.displayName;
        status.textContent = label(installation);
        status.className = "status-badge " + tone(installation);
        detail.textContent = installation
          ? "已索引 " + installation.displayName
            + (installation.version ? " · " + installation.version : "")
          : "自动查找并验证本机安装。";
        fields.hidden = !nextProvider.requiresConfiguration;
        hint.hidden = !nextProvider.requiresConfiguration;
        hint.textContent = nextProvider.requiresConfiguration
          ? "首次连接填写服务地址和 API key；已有连接可留空复用，填写两项可更新。"
          : "无需配置文件，Bridge 会自动查找本机安装。";
        action.textContent = installation && installation.isEnabled ? "重新连接" : "一键连接";
        draft.update({ baseURL: baseURL.control.value, apiKey: "" });
        validate();
      }
      function connect() {
        if (action.disabled) return;
        var values = draft.values();
        context.emit("connectAgent", {
          providerID: currentProvider.providerID,
          baseURL: currentProvider.requiresConfiguration ? values.baseURL : null,
          apiKey: currentProvider.requiresConfiguration ? values.apiKey : null
        });
        baseURL.control.value = "";
        apiKey.control.value = "";
        draft.update({ baseURL: "", apiKey: "" });
        validate();
      }
      [baseURL.control, apiKey.control].forEach(function (control) {
        control.addEventListener("input", validate);
        control.addEventListener("compositionend", validate);
      });
      action.addEventListener("click", connect);
      return { root: row, update: update };
    }

    function placeRow(row, index) {
      var current = root.children[index];
      if (current === row.root) return;
      if (current) root.insertBefore(row.root, current);
      else root.appendChild(row.root);
    }

    return {
      root: root,
      update: function (providers, installations, enabled, nextEmit) {
        context.enabled = !!enabled;
        context.emit = nextEmit;
        var visible = new Set();
        var position = 0;
        S.safeArray(providers).forEach(function (provider) {
          visible.add(provider.providerID);
          var row = rows.get(provider.providerID);
          if (!row) {
            row = createRow(provider);
            rows.set(provider.providerID, row);
          }
          var installation = S.safeArray(installations).find(function (item) {
            return item.providerID === provider.providerID;
          }) || null;
          row.update(provider, installation, nextEmit);
          placeRow(row, position);
          position += 1;
        });
        rows.forEach(function (row, providerID) {
          if (!visible.has(providerID)) {
            row.root.remove();
            rows.delete(providerID);
          }
        });
        empty.hidden = visible.size > 0;
      }
    };
  }

  global.CodexBridgeDesktopAgentConnectors = { create: create };
}(window));
