(function (global) {
  "use strict";
  var S = global.CodexBridgeDesktopPageSupport;

  function accountText(account) {
    if (!account) return "未连接";
    var errors = {
      ZCODE_START_LOGIN_REQUIRED: "请使用网页登录",
      ZCODE_API_KEY_REJECTED: "API Key 未通过验证",
      ZCODE_CREDENTIAL_INVALID: "凭据无效，请重新连接",
      ZCODE_CREDENTIAL_STORE_ERROR: "凭据存储不可用",
      ZCODE_DISCONNECT_FAILED: "断开失败，请重试",
      ZCODE_DISCONNECT_PENDING: "正在断开连接",
      ZCODE_OAUTH_ATTEMPT_EXPIRED: "登录已过期，请重试",
      ZCODE_OAUTH_FAILED: "登录失败，请重试",
      ZCODE_OAUTH_INVALID_RESPONSE: "登录服务返回无效响应",
      ZCODE_OAUTH_INVALID_URL: "登录地址无效，请重试"
    };
    if (errors[account.errorCode]) return errors[account.errorCode];
    var states = { signed_out: "未连接", authorizing: "等待授权", ready: "已连接",
      reauth_required: "需要重新登录", quota_exhausted: "额度已用尽", error: "连接失败" };
    var text = states[account.state] || "状态未知";
    return account.errorCode && /^ZCODE_[A-Z0-9_]+$/.test(account.errorCode) ? text + "（" + account.errorCode + "）" : text;
  }

  function quotaText(quota) {
    if (!quota) return "";
    var windows = quota.snapshot && S.safeArray(quota.snapshot.windows);
    if (windows && windows.length) return windows.map(function (item) {
      var value = typeof item.usedPercent === "number" ? "已用 " + item.usedPercent + "%"
        : typeof item.remaining === "number" ? "剩余 " + item.remaining + (item.unit ? " " + item.unit : "") : "";
      return item.name + (value ? "：" + value : "");
    }).join(" · ");
    return quota.errorCode || quota.snapshot && quota.snapshot.unavailable ? "额度暂不可用" : "";
  }

  function create(options) {
    var T = options.transport, active = false, busy = false, status = null, timer = null, readSequence = 0;
    var root = S.node("details", "agent-details"), body = S.node("div", "dsh-provider-content");
    var heading = S.node("summary", null, "智谱 / Z.AI");
    heading.appendChild(S.helpTooltip("智谱 / Z.AI接入说明", "此渠道涉及反代可能封禁账号，请合理使用"));
    root.appendChild(heading); root.appendChild(body);
    var platform = S.selectField("平台", "bigmodel", [
      { id: "bigmodel", title: "智谱" }, { id: "zai", title: "Z.AI" }
    ], function () { key.control.value = ""; render(); });
    var plan = S.selectField("套餐", "coding-plan", [
      { id: "coding-plan", title: "Coding Plan" }, { id: "start-plan", title: "Start Plan" }
    ], function () { render(); });
    body.appendChild(platform.wrapper); body.appendChild(plan.wrapper);
    var accountStatus = S.node("p", "hint"), quotaStatus = S.node("p", "hint");
    accountStatus.setAttribute("role", "status"); body.appendChild(accountStatus); body.appendChild(quotaStatus);
    var actions = S.node("div", "form-actions"); body.appendChild(actions);
    var login = button("网页登录", beginLogin), openLogin = button("打开登录页面", openAuthorization);
    var cancel = button("取消登录", function () { return perform("cancelLogin"); });
    var disconnect = button("断开连接", function () { return perform("disconnect"); });
    var refreshModels = button("刷新模型", function () { return perform("refreshModels"); });
    var refreshQuota = button("刷新额度", function () { return perform("refreshQuota"); });
    [login, openLogin, cancel, disconnect, refreshModels, refreshQuota].forEach(function (item) { actions.appendChild(item); });
    var keyDetails = S.node("details", "agent-details"), keyBody = S.node("div", "dsh-provider-content");
    keyDetails.appendChild(S.node("summary", null, "使用 API Key")); keyDetails.appendChild(keyBody); body.appendChild(keyDetails);
    var key = S.textField("Coding Plan API Key", "", "填写 API Key"); key.control.type = "password";
    var saveKey = button("连接", useKey); keyBody.appendChild(key.wrapper); keyBody.appendChild(saveKey);
    keyDetails.addEventListener("toggle", function () { if (!keyDetails.open) key.control.value = ""; });
    root.addEventListener("toggle", function () { if (!root.open) key.control.value = ""; });
    var feedback = S.node("p", "hint"); feedback.setAttribute("role", "status"); body.appendChild(feedback);
    render();

    function button(label, action) {
      var control = S.button(label, null, {}, null, "small");
      control.addEventListener("click", function () { if (!control.disabled) void action(); });
      return control;
    }
    function show(message) { feedback.textContent = message || ""; feedback.hidden = !message; }
    function account() {
      return status && S.safeArray(status.accounts).find(function (item) {
        return item.platform === platform.control.value && (item.plan || "coding-plan") === plan.control.value;
      });
    }
    function authInProgress() {
      return status && S.safeArray(status.accounts).some(function (item) { return item.state === "authorizing"; });
    }
    function render() {
      var row = account(), waiting = row && row.state === "authorizing", ready = row && row.state !== "signed_out";
      accountStatus.textContent = accountText(row) + (row && row.accountLabel ? " · " + row.accountLabel : "");
      var quota = status && S.safeArray(status.quotas).find(function (item) {
        return item.platform === platform.control.value && (item.plan || "coding-plan") === plan.control.value;
      });
      quotaStatus.textContent = quotaText(quota); quotaStatus.hidden = !quotaStatus.textContent;
      login.hidden = !!waiting; openLogin.hidden = !waiting || !row.login; cancel.hidden = !waiting; disconnect.hidden = !ready || !!waiting;
      keyDetails.hidden = plan.control.value !== "coding-plan";
      if (keyDetails.hidden) key.control.value = "";
      [login, openLogin, cancel, disconnect, refreshModels, refreshQuota, saveKey].forEach(function (item) { item.disabled = busy; });
      platform.control.disabled = busy; plan.control.disabled = busy; key.control.disabled = busy;
      schedule();
    }
    function update(next) {
      var before = status && S.safeArray(status.accounts);
      status = next || null;
      var becameReady = before && S.safeArray(status && status.accounts).some(function (item) {
        var old = before.find(function (other) { return other.platform === item.platform && other.plan === item.plan; });
        return item.state === "ready" && (!old || old.state !== "ready" || old.generation !== item.generation);
      });
      render();
      if (becameReady) options.modelsChanged();
    }
    function schedule() {
      if (timer) global.clearTimeout(timer);
      timer = null;
      if (active && !busy && authInProgress()) timer = global.setTimeout(function () { timer = null; void poll(); }, 2000);
    }
    function poll() {
      var sequence = ++readSequence;
      return T.call("connections.zcode", { method: "status", platform: platform.control.value }).then(function (next) {
        if (sequence === readSequence) update(next);
      }).catch(function (error) {
        if (active && sequence === readSequence) { show(error.message || "读取连接状态失败。"); schedule(); }
      });
    }
    function perform(method, extra) {
      if (busy) return Promise.resolve(false);
      busy = true; readSequence++; show(""); render();
      var payload = { method: method, platform: platform.control.value, plan: plan.control.value };
      Object.assign(payload, extra || {});
      return T.call("connections.zcode", payload).then(function (next) {
        update(next);
        if (["disconnect", "useApiKey", "refreshModels"].includes(method)) options.modelsChanged();
        return next;
      }).catch(function (error) { show(error.message || "操作失败，请重试。"); return false; }).finally(function () {
        busy = false; render();
      });
    }
    function beginLogin() {
      var chosen = platform.control.value;
      return perform("beginLogin").then(function (next) {
        if (!next) return false;
        var item = S.safeArray(next.accounts).find(function (value) { return value.platform === chosen && value.login; });
        if (!item) { show("获取登录地址失败，请重试。"); return false; }
        try { T.openExternalURL(item.login.authorizeUrl); show("请在浏览器中完成授权。"); }
        catch (error) { show(error.message || "无法打开登录地址。"); }
        return true;
      });
    }
    function openAuthorization() {
      var row = account();
      if (!row || !row.login) return;
      try { T.openExternalURL(row.login.authorizeUrl); show("请在浏览器中完成授权。"); }
      catch (error) { show(error.message || "无法打开登录地址。"); }
    }
    function useKey() {
      var value = key.control.value.trim(); key.control.value = "";
      if (!value) { show("请填写 API Key。"); return Promise.resolve(false); }
      return perform("useApiKey", { key: value });
    }
    function setActive(value) {
      active = !!value;
      if (!active) { key.control.value = ""; readSequence++; }
      schedule();
    }
    function adopt(next, expected) {
      if (!busy && (expected === undefined || expected === readSequence)) { readSequence++; update(next); }
    }
    return { root: root, setActive: setActive, update: adopt, refresh: poll, beginLogin: beginLogin, useKey: useKey,
      setError: show, revision: function () { return readSequence; } };
  }
  global.CodexBridgeDesktopEmbeddedDSHZCode = { create: create, accountText: accountText, quotaText: quotaText };
}(window));
