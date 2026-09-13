(function (global) {
  "use strict";
  var S = global.CodexBridgeDesktopPageSupport;

  function card(policy) {
    var root = S.node("section", "page-card settings-card");
    root.appendChild(S.node("h3", null, "AGY 无头运行权限"));
    var status = S.node("div", "page-message");
    var detail = S.node("p", "hint");
    root.appendChild(status);
    root.appendChild(detail);
    return {
      root: root,
      update: function (next) {
        if (!next) return;
        status.textContent = next.toolPermission === "always-proceed"
          ? "已启用 Always Proceed（总是通过）"
          : "连接 AGY 时需要同意启用 Always Proceed（总是通过）。";
        detail.textContent = next.toolPermission === "always-proceed"
          ? "AGY 无头任务会自动通过工具执行；该设置影响使用同一配置的 AGY CLI 任务。"
          : "Bridge 会在连接时向你说明作用范围，只有你确认后才会修改本机 AGY 全局配置。";
      }
    };
  }

  function create() {
    var root = S.node("div");
    var current;
    return {
      root: root,
      update: function (policy) {
        if (!policy) {
          root.hidden = true;
          return;
        }
        if (!current) {
          current = card(policy);
          root.appendChild(current.root);
        }
        root.hidden = false;
        current.update(policy);
      }
    };
  }

  global.CodexBridgeDesktopSettingsNative = { create: create, card: card };
}(window));
