(function (global) {
  "use strict";
  var S = global.CodexBridgeDesktopPageSupport;

  function accountText(account, poolAvailable) {
    if (account.disabled) return "已停用";
    if (account.blocked) return "异常受限";
    if (account.expired) return "授权过期";
    if (!account.inPool) return poolAvailable ? "未进入账号池" : "不可用";
    if (account.cooling) return "冷却中";
    if (S.safeArray(account.coolingModels).length) return "部分模型限流";
    return "可用";
  }

  function operationSummary(action, result, accounts) {
    if (action !== "accountRefresh" && action !== "accountCheckin") return "";
    var rows = S.safeArray(result && result.results);
    if (!rows.length) return action === "accountRefresh" ? "没有可刷新的账号。" : "没有可签到的账号。";
    return rows.map(function (row) {
      var account = S.safeArray(accounts).find(function (item) { return item.file === row.file; });
      var name = account && account.nickname || row.nickname || "WorkBuddy 账号";
      var text;
      if (action === "accountRefresh") {
        text = row.ok === false ? "刷新失败：" + (row.error || "请重试") : "已刷新";
        if (row.ok !== false && typeof row.credits === "number") text += "，剩余 " + row.credits + " 积分";
      } else if (row.outcome === "claimed") {
        text = "签到成功" + (typeof row.credit === "number" ? "，获得 " + row.credit + " 积分" : "");
      } else if (row.outcome === "done") text = "今日已签到";
      else if (row.outcome === "inactive") text = row.message || "签到活动未开始";
      else if (row.outcome === "ineligible") text = row.message || "此账号不支持签到";
      else if (row.outcome === "failed") text = "签到失败：" + (row.message || "请重试");
      else text = row.message || "签到结果未知";
      return name + "：" + text;
    }).join("；");
  }

  function create(options) {
    var T = options.transport, active = false, busy = false, overview = null, pending = null;
    var timer = null, pollFlight = null, authorizationVersion = 0, requestSequence = 0, rowSignature = "";
    var activeControl = null;
    var root = S.node("details", "agent-details provider-disclosure"), body = S.node("div", "dsh-provider-content");
    var heading = S.node("summary", "provider-disclosure-summary");
    heading.appendChild(S.node("span", "provider-summary-title", "WorkBuddy"));
    heading.appendChild(S.helpTooltip("WorkBuddy接入说明", "此渠道涉及反代可能封禁账号，请合理使用"));
    var summaryBadge = S.badge("未连接", "neutral");
    summaryBadge.classList.add("provider-summary-badge");
    heading.appendChild(summaryBadge);
    root.appendChild(heading); root.appendChild(body);
    var realm = S.selectField("版本", "cn", [{ id: "cn", title: "国内版" }, { id: "global", title: "国际版" }],
      function () { key.control.value = ""; }, "provider-compact-select");
    body.appendChild(realm.wrapper);
    var accountRows = S.node("div", "dsh-provider-accounts"); body.appendChild(accountRows);
    var loginState = S.node("p", "page-message provider-inline-feedback"); loginState.setAttribute("role", "status"); body.appendChild(loginState);
    var actions = S.node("div", "form-actions"); body.appendChild(actions);
    var login = button("网页登录", function () { return startLogin(); }, "primary"), openLogin = button("打开登录页面", function () { openAuthorization(); }, "primary");
    var cancelLogin = button("取消等待", cancelAuthorization);
    var importDesktop = button("导入桌面登录", function () { return perform({ action: "authDesktop", realm: realm.control.value }, importDesktop, "导入中…"); });
    var sync = button("同步模型", function () { return perform({ action: "sync" }, sync, "同步中…", "已同步"); });
    [login, openLogin, cancelLogin, importDesktop, sync].forEach(function (item) { actions.appendChild(item); });
    var keyDetails = S.node("details", "agent-details provider-subdisclosure"), keyBody = S.node("div", "dsh-provider-content");
    keyDetails.appendChild(S.node("summary", null, "使用 API Key")); keyDetails.appendChild(keyBody); body.appendChild(keyDetails);
    var key = S.textField("API Key", "", "填写 API Key"); key.control.type = "password";
    var keyActions = S.node("div", "form-actions");
    var saveKey = button("添加账号", useKey, "primary");
    keyActions.appendChild(saveKey);
    keyBody.appendChild(key.wrapper); keyBody.appendChild(keyActions);
    keyDetails.addEventListener("toggle", function () { if (!keyDetails.open) key.control.value = ""; });
    root.addEventListener("toggle", function () { if (!root.open) key.control.value = ""; });
    var preferences = S.node("div", "dsh-provider-options"), freeOnly = check("仅免费模型"), hideDsh = check("隐藏引擎名称");
    preferences.appendChild(freeOnly.wrapper); preferences.appendChild(hideDsh.wrapper); body.appendChild(preferences);
    freeOnly.control.addEventListener("change", function () { return changeOptions("freeOnly", freeOnly.control.checked); });
    hideDsh.control.addEventListener("change", function () { return changeOptions("hideDsh", hideDsh.control.checked); });
    var feedback = S.node("p", "page-message provider-inline-feedback"); feedback.setAttribute("role", "status"); body.appendChild(feedback);
    render();

    function button(label, action, extraClass) {
      var control = S.button(label, null, {}, null, "small" + (extraClass ? " " + extraClass : ""));
      control.addEventListener("click", function () { if (!control.disabled) void action(control); });
      return control;
    }
    function check(label) {
      var wrapper = S.node("label", "check-field dsh-provider-check"), control = S.node("input");
      control.type = "checkbox"; wrapper.appendChild(control); wrapper.appendChild(S.node("span", null, label));
      return { wrapper: wrapper, control: control };
    }
    function show(message, tone) {
      feedback.className = "page-message provider-inline-feedback" + (tone ? " " + tone : "");
      feedback.textContent = message || ""; feedback.hidden = !message;
    }
    function render() {
      var rows = overview && S.safeArray(overview.accounts) || [];
      var activeCount = rows.filter(function (row) { return !row.disabled && !row.expired && !row.blocked; }).length;
      if (pending) {
        summaryBadge.textContent = "等待授权";
        summaryBadge.className = "status-badge provider-summary-badge warning";
      } else if (activeCount > 0) {
        summaryBadge.textContent = "已连接 " + activeCount + " 个账号";
        summaryBadge.className = "status-badge provider-summary-badge success";
      } else if (rows.length > 0) {
        summaryBadge.textContent = rows.length + " 个账号待处理";
        summaryBadge.className = "status-badge provider-summary-badge warning";
      } else {
        summaryBadge.textContent = "未连接";
        summaryBadge.className = "status-badge provider-summary-badge neutral";
      }
      var signature = JSON.stringify([rows, overview && overview.poolAvailable, busy]);
      if (signature !== rowSignature) { rowSignature = signature; renderAccounts(rows); }
      var settings = overview && overview.options || {};
      freeOnly.control.checked = settings.freeOnly === true; hideDsh.control.checked = settings.hideDsh === true;
      [login, openLogin, cancelLogin, importDesktop, sync, saveKey].forEach(function (item) {
        item.disabled = busy || item === activeControl;
      });
      [realm.control, key.control, freeOnly.control, hideDsh.control].forEach(function (item) { item.disabled = busy; });
      login.hidden = !!pending; openLogin.hidden = !pending; cancelLogin.hidden = !pending;
      loginState.textContent = pending ? (pending.scanned ? "已打开授权，请完成确认。" : "等待浏览器授权。") : "";
      loginState.hidden = !pending;
      schedule();
    }
    function renderAccounts(rows) {
      S.clear(accountRows);
      if (!rows.length) { accountRows.appendChild(S.node("p", "hint", "添加账号后可使用 WorkBuddy 模型。")); return; }
      rows.forEach(function (account) {
        var row = S.node("div", "dsh-provider-account");
        var copy = S.node("div", "dsh-provider-account-copy"), titleRow = S.node("div", "plugin-card-title-row");
        titleRow.appendChild(S.node("strong", "plugin-card-title", account.nickname || "WorkBuddy 账号"));
        var stateLabel = accountText(account, overview.poolAvailable);
        var stateTone = stateLabel === "可用" ? "success" : stateLabel === "已停用" ? "neutral" : "warning";
        titleRow.appendChild(S.badge(stateLabel, stateTone));
        copy.appendChild(titleRow);
        var text = account.realm === "global" ? "国际版" : "国内版";
        if (typeof account.credits === "number") text += " · 剩余 " + account.credits + " 积分";
        copy.appendChild(S.node("span", "hint", text));
        row.appendChild(copy);
        var controls = S.node("div", "form-actions");
        if (account.realm === "cn") {
          controls.appendChild(button("签到", function (btn) { return perform({ action: "accountCheckin", file: account.file }, btn, "签到中…"); }));
        }
        controls.appendChild(button("刷新账号", function (btn) { return perform({ action: "accountRefresh", file: account.file }, btn, "刷新中…"); }));
        controls.appendChild(button(account.disabled ? "启用" : "停用", function (btn) {
          return perform({ action: "accountDisabled", file: account.file, disabled: !account.disabled }, btn, account.disabled ? "启用中…" : "停用中…");
        }));
        controls.appendChild(button("移除", function (btn) {
          return S.confirmDialog({
            title: "移除 WorkBuddy 账号",
            message: "确定移除“" + (account.nickname || "WorkBuddy 账号") + "”？",
            confirmTitle: "移除账号",
            danger: true,
            fallbackText: "移除这个 WorkBuddy 账号？"
          }).then(function (confirmed) {
            if (!confirmed) return false;
            return perform({ action: "accountDelete", file: account.file }, btn, "移除中…");
          });
        }, "danger"));
        Array.from(controls.querySelectorAll("button")).forEach(function (item) { item.disabled = busy; });
        row.appendChild(controls); accountRows.appendChild(row);
      });
    }
    function update(value) { overview = value || null; render(); }
    function changeOptions(name, value) {
      var request = { action: "gatewayOptions" }; request[name] = value;
      return perform(request);
    }
    function perform(request, triggerButton, pendingLabel, doneLabel) {
      if (busy) return Promise.resolve(false);
      busy = true; activeControl = triggerButton || null; show("");
      var restore = triggerButton ? (triggerButton.__restoreTitle || triggerButton.textContent) : "";
      if (triggerButton && S.setButtonPending) S.setButtonPending(triggerButton, true, pendingLabel || "处理中…", restore);
      render();
      var sequence = ++requestSequence;
      return T.call("connections.workbuddy", { request: request }).then(function (response) {
        if (sequence === requestSequence && response.overview) update(response.overview);
        var summary = operationSummary(request.action, response.result, response.overview && response.overview.accounts);
        show([summary, response.modelError].filter(Boolean).join("；"), response.modelError ? "warning" : "");
        if (["authKey", "authDesktop", "accountDisabled", "accountDelete", "accountRefresh", "gatewayOptions", "sync"].includes(request.action)) {
          options.modelsChanged();
        }
        if (triggerButton && doneLabel && S.flashButtonSuccess) S.flashButtonSuccess(triggerButton, doneLabel);
        return response;
      }).catch(function (error) { show(error.message || "操作失败，请重试。", "error"); return false; }).finally(function () {
        if (triggerButton && S.setButtonPending && !triggerButton.__flashTimer) S.setButtonPending(triggerButton, false, null, restore);
        activeControl = null; busy = false; render();
      });
    }
    function openAuthorization() {
      if (!pending) return;
      try { T.openExternalURL(pending.url); }
      catch (error) { show(error.message || "无法打开登录地址。", "error"); }
    }
    function startLogin() {
      return perform({ action: "authStart", realm: realm.control.value }, login, "打开中…").then(function (response) {
        if (!response) return false;
        var url = response.result && response.result.authUrl;
        if (!url) { show("获取登录地址失败，请重试。", "error"); return false; }
        authorizationVersion++; pending = { url: url, scanned: false }; render(); openAuthorization();
        return true;
      });
    }
    function cancelAuthorization() { authorizationVersion++; pending = null; render(); }
    function useKey() {
      var value = key.control.value.trim(); key.control.value = "";
      if (!value) { show("请填写 API Key。", "warning"); return Promise.resolve(false); }
      return perform({ action: "authKey", realm: realm.control.value, key: value }, saveKey, "添加中…");
    }
    function schedule() {
      if (timer) global.clearTimeout(timer);
      timer = null;
      if (active && pending && !busy && !pollFlight) timer = global.setTimeout(function () { timer = null; void poll(); }, 2000);
    }
    function poll() {
      if (!active || !pending || busy) return Promise.resolve(false);
      if (pollFlight) return pollFlight.promise;
      if (timer) global.clearTimeout(timer);
      timer = null;
      var version = authorizationVersion, sequence = ++requestSequence;
      var flight = { promise: null }; pollFlight = flight;
      flight.promise = T.call("connections.workbuddy", { request: { action: "authPoll" } }).then(function (response) {
        if (version !== authorizationVersion || !pending) return false;
        var current = sequence === requestSequence;
        if (current && response.overview) update(response.overview);
        var result = response.result || {};
        if (result.status === "success") {
          pending = null; authorizationVersion++; options.modelsChanged();
          if (current) show(response.modelError || "账号已连接。");
        } else if (result.status === "expired" || result.status === "invalid") {
          pending = null; authorizationVersion++;
          if (current) show(result.error || "授权已过期，请重新登录。");
        } else if (current) pending.scanned = result.status === "scanned";
        render(); return true;
      }).catch(function (error) {
        if (version === authorizationVersion && sequence === requestSequence && active) show(error.message || "读取登录状态失败。");
        return false;
      }).finally(function () {
        if (pollFlight === flight) { pollFlight = null; schedule(); }
      });
      return flight.promise;
    }
    function setActive(value) {
      active = !!value;
      if (!active) key.control.value = "";
      schedule();
    }
    function adopt(value, expected) {
      if (!busy && (expected === undefined || expected === requestSequence)) { requestSequence++; update(value); }
    }
    return { root: root, setActive: setActive, update: adopt, poll: poll, beginLogin: startLogin,
      cancelLogin: cancelAuthorization, useKey: useKey,
      setError: show, revision: function () { return requestSequence; } };
  }
  global.CodexBridgeDesktopEmbeddedDSHWorkBuddy = { create: create, accountText: accountText, operationSummary: operationSummary };
}(window));
