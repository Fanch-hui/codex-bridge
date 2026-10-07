(function (global) {
  "use strict";
  var S = global.CodexBridgeDesktopPageSupport;
  var D = global.CodexBridgeDesktopFormDraft;
  function createClients(emit) {
    var context = { emit: emit };
    var card = S.node("div", "page-card connection-card");
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
      var controls = S.node("div", "client-controls");
      var exposure = S.selectField("客户端工具权限", client.exposureMode, client.exposureOptions, function (value) {
        context.emit("setMCPClientExposure", {
          clientID: row.dataset.clientID,
          exposureMode: value
        });
        exposure.control.setAttribute("aria-busy", "true");
      }, "client-exposure");
      controls.appendChild(exposure.wrapper);
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
      controls.appendChild(toggle);
      var copy = S.button("复制 Qwen JSON 配置", null, {}, null, "small", true);
      copy.addEventListener("click", function () {
        context.emit("copyMCPClientConfiguration", { clientID: row.dataset.clientID });
      });
      controls.appendChild(copy);
      var rotate = S.button("重新生成凭证", null, {}, null, "small danger", true);
      rotate.addEventListener("click", function () {
        if (global.confirm("重新生成这个 MCP 客户端的凭证？现有配置将立即失效。")) {
          context.emit("rotateMCPClientCredential", { clientID: row.dataset.clientID });
        }
      });
      controls.appendChild(rotate);
      row.appendChild(controls);
      var hint = S.node("p", "client-exposure-hint");
      row.appendChild(hint);
      var draft = D.bind({ exposure: exposure.control, enabled: checkbox });
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
        hint: hint
      };
    }
    function updateRow(row, client, nextEmit) {
      row.root.dataset.clientID = client.clientID;
      row.name.textContent = client.displayName;
      S.updateStatus(row.state,
        client.enabled ? "已启用" : "已停用", client.enabled ? "success" : "neutral");
      row.detail.textContent = client.activeSessionCount ? "活动会话 " + client.activeSessionCount : "";
      row.detail.hidden = !row.detail.textContent;
      D.selectOptions(row.exposure, client.exposureOptions || [], false);
      row.draft.update({ exposure: client.exposureMode || "full", enabled: !!client.enabled });
      row.exposure.disabled = !client.exposureOptions || !client.exposureOptions.length;
      row.checkbox.disabled = !client.canToggle;
      row.exposure.setAttribute("aria-busy", "false");
      row.checkbox.setAttribute("aria-busy", "false");
      row.toggle.hidden = !client.canToggle;
      row.toggleText.textContent = client.clientID === "qwen.studio" ? "启用 Qwen Studio" : "启用";
      row.copy.hidden = !client.canCopyConfiguration;
      row.rotate.hidden = !client.canRotateCredential;
      row.copy.disabled = !client.enabled || !client.canCopyConfiguration;
      row.rotate.disabled = !client.enabled || !client.canRotateCredential;
      row.hint.textContent = "客户端工具权限决定可用的 MCP 工具；Agent 任务权限在工作台选择。";
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
          updateRow(row, client, nextEmit);
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
