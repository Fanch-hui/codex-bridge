(function (global) {
  "use strict";

  var pending = new Map(), callQueue = [], activeCalls = 0, drainingCalls = false, sequence = 0, sender = null;
  var enabled = true;
  var reads = new Map(), readQueue = [], activeReads = 0, retryDelays = [100, 250, 500];

  function requestID() {
    if (global.crypto && global.crypto.randomUUID) return global.crypto.randomUUID();
    return "dsh-" + Date.now().toString(36) + "-" + (++sequence).toString(36);
  }

  function configure(emit) { sender = emit; }

  function unavailable() {
    var error = new Error("工作台当前不可用。");
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

  function openExternalURL(value) {
    if (!sender) throw new Error("后台 Service 未连接。");
    var url = new URL(value);
    if (url.protocol !== "https:" || url.username || url.password || url.port) {
      throw new Error("登录地址无效，请重试。");
    }
    sender("openExternalURL", { value: url.href });
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
    var entry = { id: id, action: action, input: input, sender: sender, timeoutMs: options.timeoutMs || 60000,
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
            var error = new Error("请求未确认，请重试。");
            error.code = "embedded_dsh_transport_timeout";
            finishCall(current, true, error);
          };
        }(entry), entry.timeoutMs);
        if (entry.timer && entry.timer.unref) entry.timer.unref();
        try { entry.sender("embeddedDSH", { action: entry.action, input: entry.input }, entry.id); }
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
    if (error.code === "busy" && error.retryable === true) return true;
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
      catch (_) { finishCall(current, true, new Error("工作台引擎返回了无效结果。")); return; }
      finishCall(current, false, result);
    });
  }

  global.CodexBridgeDesktopEmbeddedDSHTransport = { configure: configure, setEnabled: setEnabled, call: call, read: read,
    receive: receive, requestID: requestID, openExternalURL: openExternalURL };
}(window));
