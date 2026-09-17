(function (global) {
  "use strict";
  function confirmation(S, message, onConfirm) {
    var root = S.node("div", "agent-confirmation");
    root.hidden = true;
    root.appendChild(S.node("span", null, message));
    var confirmButton = S.button("确认", null, {}, null, "small primary", false);
    var cancelButton = S.button("取消", null, {}, null, "small", false);
    root.appendChild(confirmButton);
    root.appendChild(cancelButton);
    confirmButton.addEventListener("click", function () {
      if (root.hidden) return;
      onConfirm();
      root.hidden = true;
    });
    cancelButton.addEventListener("click", function () { root.hidden = true; });
    return {
      root: root,
      open: function () {
        root.hidden = false;
        confirmButton.focus();
      },
      close: function () { root.hidden = true; }
    };
  }

  function createInstallationDetail(S, installation, reprobe, toggle, remove) {
    var root = S.node("div", "agent-installation-detail");
    var heading = S.node("div", "agent-installation-heading");
    var name = S.node("strong");
    var badge = S.badge("未知", "neutral");
    heading.appendChild(name);
    heading.appendChild(badge);
    root.appendChild(heading);
    var path = S.node("div", "row-detail mono");
    var metadata = S.node("div", "row-detail");
    var error = S.node("div", "row-detail agent-error");
    root.appendChild(path);
    root.appendChild(metadata);
    root.appendChild(error);

    var actions = S.node("div", "agent-installation-actions");
    var probe = S.button("重新检查", null, {}, null, "small", true);
    var accept = S.button("确认更新并检查", null, {}, null, "small primary", true);
    var disconnect = S.button("断开连接", null, {}, null, "small", true);
    var removeButton = S.button("移除登记", null, {}, null, "small danger", true);
    actions.appendChild(probe);
    actions.appendChild(accept);
    actions.appendChild(disconnect);
    actions.appendChild(removeButton);
    root.appendChild(actions);

    var removal = confirmation(
      S,
      "移除这条 Agent 登记？本机文件不会被删除。",
      function () { remove(current); }
    );
    root.appendChild(removal.root);
    var current = installation;
    var replacement = confirmation(
      S,
      "确认新的 Agent 文件并重新检查？",
      function () { reprobe(current, true); }
    );
    root.appendChild(replacement.root);

    probe.addEventListener("click", function () {
      if (!probe.disabled) reprobe(current, false);
    });
    accept.addEventListener("click", function () {
      if (!accept.disabled) replacement.open();
    });
    disconnect.addEventListener("click", function () {
      if (!disconnect.disabled) toggle(current, false);
    });
    removeButton.addEventListener("click", function () {
      if (!removeButton.disabled) removal.open();
    });

    return {
      root: root,
      update: function (next, context, pending) {
        current = next;
        name.textContent = next.displayName;
        badge.textContent = availabilityLabel(next.availability, next.enabled);
        badge.className = "status-badge " + availabilityTone(next.availability, next.enabled);
        path.textContent = next.executablePath || "未提供可执行路径";
        metadata.textContent = (next.version || "未识别")
          + " · ACP " + (next.protocolRevision || "未协商")
          + " · Adapter r" + next.adapterRevision
          + " · 有效能力 " + S.safeArray(next.effectiveCapabilities).length + " 项";
        error.textContent = next.lastProbeError || "";
        error.hidden = !next.lastProbeError;
        probe.disabled = context.busy || pending || !next.canReprobe;
        accept.hidden = next.availability !== "needs_review";
        accept.disabled = context.busy || pending || !next.canReprobe;
        disconnect.hidden = !next.enabled;
        disconnect.disabled = context.busy || pending || !next.canToggle;
        removeButton.disabled = context.busy || pending || !next.canRemove;
        if (accept.hidden) replacement.close();
        if (!next.canRemove) removal.close();
      }
    };
  }

  function availabilityLabel(value, enabled) {
    if (value === "available" && enabled === true) return "已连接";
    if (value === "available") return "已发现";
    if (value === "needs_review") return "需确认更新";
    if (value === "unavailable") return "不可用";
    return "未知";
  }

  function availabilityTone(value, enabled) {
    if (value === "available" && enabled === true) return "success";
    if (value === "available" || value === "needs_review") return "warning";
    if (value === "unavailable") return "error";
    return "neutral";
  }

  global.CodexBridgeDesktopAgentConnectorDetails = {
    confirmation: confirmation,
    createInstallationDetail: createInstallationDetail,
    availabilityLabel: availabilityLabel,
    availabilityTone: availabilityTone
  };
}(window));
