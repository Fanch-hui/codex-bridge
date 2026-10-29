(function (global) {
  "use strict";
  var S = global.CodexBridgeDesktopPageSupport;
  var D = global.CodexBridgeDesktopFormDraft;
  function createClients(emit, options) {
    options = options || {};
    var permissionsOnly = options.mode === "permissions";
    var connectionOnly = options.mode === "connection";
    var context = { emit: emit };
    var card = S.node("div", "page-card connection-card client-settings-card"
      + (permissionsOnly ? " client-permissions-card" : ""));
    var rows = new Map();
    function createRow(client) {
      var row = S.node("div", "client-row");
      var main = S.node("div", "row-main");
      var heading = S.node("div", "client-heading");
      var name = S.node("h3");
      var state = S.badge("未知", "neutral");
      heading.appendChild(name);
      heading.appendChild(state);
      main.appendChild(heading);
      var detail = S.node("p", "card-subtitle");
      main.appendChild(detail);
      row.appendChild(main);
      var controls = S.node("div", "client-settings-controls");
      var exposure = S.selectField("工具权限", client.exposureMode, client.exposureOptions, function (value) {
        context.emit("setMCPClientExposure", {
          clientID: row.dataset.clientID,
          exposureMode: value
        });
        exposure.control.setAttribute("aria-busy", "true");
      }, "client-exposure");
      if (!connectionOnly) controls.appendChild(exposure.wrapper);
      var permissionLink = S.button("客户端权限", null, {}, null, "small", false);
      permissionLink.hidden = !connectionOnly;
      permissionLink.addEventListener("click", function () {
        if (global.CodexBridgeDesktopSettingsPage) {
          global.CodexBridgeDesktopSettingsPage.openDetail("permissions", context.emit);
        }
      });
      controls.appendChild(permissionLink);
      var toggle = S.node("label", "check-field");
      var checkbox = S.node("input");
      var toggleText = S.node("span");
      checkbox.type = "checkbox";
      checkbox.addEventListener("change", function () {
        context.emit("setMCPClientEnabled", {
          clientID: row.dataset.clientID,
          enabled: checkbox.checked
        });
        checkbox.setAttribute("aria-busy", "true");
      });
      toggle.appendChild(checkbox);
      toggle.appendChild(toggleText);
      heading.insertBefore(toggle, state);
      var actions = S.node("div", "client-settings-actions");
      var copy = S.button("复制 Qwen JSON 配置", null, {}, null, "small", true);
      copy.addEventListener("click", function () {
        context.emit("copyMCPClientConfiguration", { clientID: row.dataset.clientID });
      });
      actions.appendChild(copy);
      var rotate = S.button("重新生成凭证", null, {}, null, "small danger", true);
      rotate.addEventListener("click", function () {
        var confirmation = row.dataset.clientID === "google.gemini"
          ? "重置 Gemini 连接？现有会话将断开，请在 Gemini 中重新连接。"
          : "重新生成这个 MCP 客户端的凭证？现有配置将立即失效。";
        if (global.confirm(confirmation)) {
          context.emit("rotateMCPClientCredential", { clientID: row.dataset.clientID });
        }
      });
      actions.appendChild(rotate);
      controls.appendChild(actions);
      row.appendChild(controls);
      var draft = D.bind(connectionOnly ? { enabled: checkbox } : { exposure: exposure.control, enabled: checkbox });
      return {
        root: row,
        name: name,
        state: state,
        detail: detail,
        exposure: exposure.control,
        toggle: toggle, checkbox: checkbox, toggleText: toggleText,
        draft: draft,
        copy: copy,
        rotate: rotate,
        actions: actions
      };
    }
    function updateRow(row, client, nextEmit, singleClient) {
      row.root.dataset.clientID = client.clientID;
      row.name.textContent = client.displayName;
      row.name.hidden = singleClient && !permissionsOnly;
      S.updateStatus(row.state,
        client.enabled ? "已启用" : "已停用", client.enabled ? "success" : "neutral");
      var details = [];
      if (client.activeSessionCount) details.push("活动会话 " + client.activeSessionCount);
      if (client.lastConnectedAt) details.push("最近连接：" + client.lastConnectedAt);
      row.detail.textContent = details.join(" · ");
      row.detail.hidden = !row.detail.textContent;
      D.selectOptions(row.exposure, client.exposureOptions || [], false);
      row.draft.update({ exposure: client.exposureMode || "full", enabled: !!client.enabled });
      row.exposure.disabled = !client.exposureOptions || !client.exposureOptions.length;
      row.checkbox.disabled = !client.canToggle;
      row.exposure.setAttribute("aria-busy", "false");
      row.checkbox.setAttribute("aria-busy", "false");
      row.toggle.hidden = permissionsOnly || !client.canToggle;
      row.state.hidden = permissionsOnly;
      var gemini = client.clientID === "google.gemini";
      row.toggleText.textContent = singleClient ? "启用连接" : "启用 " + client.displayName;
      row.copy.textContent = gemini ? "复制本地启动命令" : "复制 Qwen JSON 配置";
      row.rotate.textContent = gemini ? "重置连接" : "重新生成凭证";
      row.copy.hidden = permissionsOnly || !client.canCopyConfiguration || options.hideCopy === true;
      row.rotate.hidden = permissionsOnly || !client.canRotateCredential;
      row.actions.hidden = row.copy.hidden && row.rotate.hidden;
      row.copy.disabled = !client.enabled || !client.canCopyConfiguration;
      row.rotate.disabled = !client.enabled || !client.canRotateCredential;
      row.detail.hidden = permissionsOnly || !row.detail.textContent;
      context.emit = nextEmit;
    }
    function placeRow(card, row, index) {
      var current = card.children[index];
      if (current === row.root) return;
      if (current) card.insertBefore(row.root, current);
      else card.appendChild(row.root);
    }
    return {
      root: card,
      update: function (clients, nextEmit) {
        context.emit = nextEmit;
        var visible = new Set();
        var position = 0;
        S.safeArray(clients).forEach(function (client) {
          visible.add(client.clientID);
          var row = rows.get(client.clientID);
          if (!row) {
            row = createRow(client);
            rows.set(client.clientID, row);
          }
          updateRow(row, client, nextEmit, S.safeArray(clients).length === 1);
          placeRow(card, row, position);
          position += 1;
        });
        rows.forEach(function (row, clientID) {
          if (!visible.has(clientID)) {
            row.root.remove();
            rows.delete(clientID);
          }
        });
        if (!visible.size) {
          var empty = card.querySelector(".list-empty");
          if (!empty) card.appendChild(S.node("div", "list-empty", "暂无本地 MCP 客户端。"));
        } else {
          var emptyRow = card.querySelector(".list-empty");
          if (emptyRow) emptyRow.remove();
        }
      }
    };
  }
  global.CodexBridgeDesktopConnectionsClients = { create: createClients };
}(window));
