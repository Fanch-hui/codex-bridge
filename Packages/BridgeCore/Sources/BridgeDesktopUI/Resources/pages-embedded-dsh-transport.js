(function (global) {
  "use strict";

  function create(configuration) {
  var pending = new Map(), callQueue = [], activeCalls = 0, drainingCalls = false, sequence = 0, sender = null;
  var enabled = true;
  var reads = new Map(), readQueue = [], activeReads = 0, retryDelays = [100, 250, 500];

  function requestID() {
    if (global.crypto && global.crypto.randomUUID) return configuration.prefix + global.crypto.randomUUID();
    return (configuration.prefix || "dsh-") + Date.now().toString(36) + "-" + (++sequence).toString(36);
  }

  function configure(emit) { sender = emit; }

  function unavailable() {
    var error = new Error(configuration.unavailable);
    error.code = "workbench_disabled";
    return error;
  }

  function setEnabled(value) {
    enabled = !!value;
    if (enabled) return;
    callQueue.splice(0).forEach(function (entry) {
      if (pending.get(entry.id) !== entry) return;
      pending.delete(entry.id);
      entry.reject(unavailable());
    });
  }

  function openExternalURL(value, localLoginPath) {
    if (!sender) throw new Error("后台 Service 未连接。");
    var url = new URL(value);
    var publicHTTPS = url.protocol === "https:" && !url.port;
    var localLogin = localLoginPath && url.protocol === "http:" && url.hostname === "127.0.0.1"
      && Number(url.port) >= 1024 && !url.search && !url.hash && localLoginPath.test(url.pathname);
    if ((!publicHTTPS && !localLogin) || url.username || url.password) {
      throw new Error("登录地址无效，请重试。");
    }
    sender("openExternalURL", { value: url.href });
  }

  function timeoutFor(action, requested) {
    if (configuration.command !== "providerGateway") return requested || 60000;
    var minimum = 0;
    if (/^plugins\.(install|update)$/.test(action)) minimum = 2160000;
    else if (/^plugins\./.test(action)) minimum = 1860000;
    else if (action === "provider.call" || action === "models.refresh") minimum = 660000;
    return Math.max(requested || 60000, minimum);
  }

  function call(action, payload, options) {
    options = options || {};
    if (!enabled) return Promise.reject(unavailable());
    if (!sender) return Promise.reject(new Error("后台 Service 未连接。"));
    var id = options.requestID || requestID();
    if (pending.has(id)) return pending.get(id).promise;
    var input;
    try { input = JSON.stringify(payload || {}); } catch (error) { return Promise.reject(error); }
    var resolveRequest, rejectRequest;
    var promise = new Promise(function (resolve, reject) { resolveRequest = resolve; rejectRequest = reject; });
    var readOnly = action === "status" || ["plugins.usage", "plugins.authMethods", "plugins.catalog"].indexOf(action) !== -1 || action === "provider.call" && payload
      && ["status", "auth.status", "models.list", "settings.get", "connections.status",
        "configuration.status"].indexOf(payload.action) !== -1;
    var entry = { id: id, action: action, input: input, sender: sender, command: options.command || configuration.command,
      readOnly: readOnly,
      timeoutMs: timeoutFor(action, options.timeoutMs),
      promise: promise, resolve: resolveRequest, reject: rejectRequest, sent: false, timer: null };
    pending.set(id, entry); callQueue.push(entry); drainCalls();
    return promise;
  }

  function drainCalls() {
    if (drainingCalls) return;
    drainingCalls = true;
    try {
      while (activeCalls < 4 && callQueue.length) {
        var entry = callQueue.shift();
        if (pending.get(entry.id) !== entry) continue;
        entry.sent = true; activeCalls++;
        entry.timer = global.setTimeout(function (current) {
          return function () {
            var message = current.readOnly ? "读取供应商状态超时，请稍后刷新。"
              : "请求未收到确认，请查看当前状态后再操作。";
            var error = new Error(message);
            error.code = "embedded_dsh_transport_timeout";
            finishCall(current, true, error);
          };
        }(entry), entry.timeoutMs);
        if (entry.timer && entry.timer.unref) entry.timer.unref();
        try { entry.sender(entry.command, { action: entry.action, input: entry.input }, entry.id); }
        catch (error) { finishCall(entry, true, error); }
      }
    } finally { drainingCalls = false; }
  }

  function finishCall(entry, failed, result) {
    if (pending.get(entry.id) !== entry) return;
    pending.delete(entry.id); global.clearTimeout(entry.timer); activeCalls--;
    if (failed) entry.reject(result); else entry.resolve(result);
    drainCalls();
  }

  function read(key, operation) {
    if (!enabled) return Promise.reject(unavailable());
    var entry = reads.get(key), created = !entry;
    if (created) {
      entry = { key: key, operation: operation, next: null, state: "queued", retries: 0 };
      entry.promise = new Promise(function (resolve, reject) { entry.resolve = resolve; entry.reject = reject; });
      reads.set(key, entry);
    } else if (entry.state === "queued" && !entry.retries && !entry.next) {
      entry.operation = operation;
    } else {
      entry.next = operation;
    }
    if (created) { readQueue.push(entry); drainReads(); }
    return entry.promise;
  }

  function drainReads() {
    while (activeReads < 3 && readQueue.length) {
      var entry = readQueue.shift();
      entry.state = "running"; activeReads++;
      runRead(entry);
    }
  }

  function runRead(entry) {
    var operation = entry.operation;
    Promise.resolve().then(operation).then(function (value) {
      finishRead(entry, false, value);
    }, function (error) {
      finishRead(entry, true, error);
    });
  }

  function finishRead(entry, failed, result) {
    activeReads--;
    if (failed && canRetryRead(entry, result) && entry.retries < retryDelays.length) {
      var delay = retryDelays[entry.retries++];
      entry.state = "waiting";
      global.setTimeout(function () { enqueueRead(entry); }, delay);
      drainReads();
      return;
    }
    if (entry.next) {
      entry.operation = entry.next; entry.next = null; entry.retries = 0;
      enqueueRead(entry);
    } else {
      reads.delete(entry.key);
      if (failed) entry.reject(result); else entry.resolve(result);
      drainReads();
    }
  }

  function canRetryRead(entry, error) {
    if (!error) return false;
    if ((error.code === "busy" || error.code === "community_provider_busy") && error.retryable === true) return true;
    if (!/^startup\.(status|graph)(:|$)/.test(entry.key)) return false;
    return error.code === "embedded_dsh_transport_timeout"
      || error.code === "embedded_dsh_runtime" && error.retryable === true;
  }

  function enqueueRead(entry) {
    entry.state = "queued"; readQueue.push(entry); drainReads();
  }

  function receive(receipts) {
    (receipts || []).forEach(function (receipt) {
      var current = pending.get(receipt.requestID);
      if (!current || !current.sent) return;
      if (receipt.errorMessage) {
        var error = new Error(receipt.errorMessage);
        error.code = receipt.errorCode; error.retryable = receipt.retryable;
        finishCall(current, true, error); return;
      }
      var result;
      try { result = JSON.parse(receipt.resultJSON); }
      catch (_) { finishCall(current, true, new Error("后台服务返回了无效结果。")); return; }
      finishCall(current, false, result);
    });
  }

  return { configure: configure, setEnabled: setEnabled, call: call, read: read,
    receive: receive, requestID: requestID, openExternalURL: openExternalURL };
  }
  global.CodexBridgeDesktopEmbeddedDSHTransport = create({ command: "embeddedDSH", prefix: "",
    unavailable: "工作台当前不可用。" });
  var gateway = create({ command: "providerGateway", prefix: "provider-",
    unavailable: "供应商服务当前不可用。" });
  gateway.openPluginLogin = function (value, plugin, provider) {
    var localPath;
    if (plugin && plugin.package === "magpie-providers-hub" && plugin.version === "0.13.2"
        && (provider === "hub-astudio" || provider === "hub-loomy"
          || provider === "hub-magicrew" || provider === "hub-magicrew-intl"
          || provider === "hub-monkeycode" || provider === "hub-monkeycode-intl")) localPath = /^\/login$/;
    if (plugin && plugin.package === "magpie-plugin-codar" && plugin.version === "0.3.0"
        && provider === "codar") localPath = /^\/s\/[0-9a-f]{32}\/$/;
    gateway.openExternalURL(value, localPath);
  };
  gateway.supplierTransport = function (fallback) {
    return {
      call: function (action, payload, options) {
        if (fallback && (action === "configuration.status" || action === "runtime.applyWhenIdle")) {
          return fallback.call(action, payload, options);
        }
        if (/^(auth|settings|models|connections)\./.test(action)
          || action === "configuration.status" || action === "runtime.applyWhenIdle") {
          return gateway.call("provider.call", { action: action, payload: payload || {} }, options);
        }
        if (fallback) return fallback.call(action, payload, options);
        return Promise.reject(new Error("当前页面不支持此操作。"));
      },
      read: gateway.read,
      openExternalURL: gateway.openExternalURL
    };
  };
  global.CodexBridgeDesktopProviderGatewayTransport = gateway;
}(window));
