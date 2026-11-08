(function (global) {
  "use strict";
  var submissions = new Map(), revision = 0, refresh = null, sequence = 0;
  var storageKey = "codexbridge.web-workbench.operations.v1", restored = false, settled = null;
  var delays = [1000, 2000, 4000, 8000, 15000, 30000, 60000];

  function newRequestID() {
    sequence += 1;
    return "workbench-" + Date.now().toString(36) + "-" + sequence + "-"
      + Math.random().toString(36).slice(2, 10);
  }

  function bind(page, onChange) {
    refresh = page ? onChange : null;
    restore();
    if (page) submissions.forEach(function (pending) {
      if (pending.durable && pending.state === "checking" && !pending.timer && !pending.inFlight) {
        schedule(pending, 0);
      }
    });
  }

  function changed(follow) {
    revision += 1;
    persist();
    if (refresh) refresh(follow);
  }

  function persist() {
    try {
      var rows = Array.from(submissions.values()).filter(function (pending) { return pending.durable; })
        .map(function (pending) {
          return { requestID: pending.requestID, command: pending.command, taskID: pending.taskID,
            projectID: pending.projectID, providerID: pending.providerID, sessionID: pending.sessionID,
            input: pending.input, mode: pending.mode, visible: pending.visible, state: pending.state,
            resultingTaskID: pending.resultingTaskID, payload: pending.payload,
            resubmitted: pending.resubmitted === true, baselineIDs: Array.from(pending.baselineIDs || []) };
        });
      global.localStorage.setItem(storageKey, JSON.stringify(rows));
      return true;
    } catch (_) { return false; }
  }

  function restore() {
    if (restored) return;
    restored = true;
    try {
      var rows = JSON.parse(global.localStorage.getItem(storageKey) || "[]");
      if (!Array.isArray(rows)) return;
      rows.forEach(function (row) {
        if (!row || !row.requestID || !row.taskID || submissions.has(row.requestID)) return;
        row.durable = true; row.baselineIDs = new Set(row.baselineIDs || []);
        if (row.state === "sending") row.state = "checking";
        submissions.set(row.requestID, row);
      });
    } catch (_) {}
  }

  // Sessions of every project are open at once, so a submission belongs to the project of the
  // session it was sent to rather than to the project currently being viewed.
  function projectOf(page) {
    var detail = page && page.selectedTask;
    if (detail && detail.projectID) return detail.projectID;
    if (detail && page && Array.isArray(page.tasks)) {
      var matched = page.tasks.find(function (item) { return item.taskID === detail.taskID; });
      if (matched && matched.projectID) return matched.projectID;
    }
    return page && page.selectedProjectID;
  }

  function begin(page, request) {
    var detail = page && page.selectedTask || {};
    submissions.forEach(function (previous, requestID) {
      if (previous.state === "failed" && previous.taskID === request.taskID
        && previous.input === request.input) submissions.delete(requestID);
    });
    var immediate = request.command === "resumeTask"
      || (request.command === "steerTask" && request.mode === "interrupt-current-then-continue");
    var pending = Object.assign({}, request, {
      projectID: projectOf(page),
      providerID: detail.providerID,
      sessionID: detail.sessionID || detail.taskID,
      baselineReceiptID: page && page.commandReceipt && page.commandReceipt.receiptID,
      baselineIDs: new Set((detail.conversation || []).map(function (entry) { return entry.id; })),
      visible: immediate && typeof request.input === "string" && !!request.input.trim(),
      state: "sending"
    });
    submissions.set(request.requestID, pending);
    changed(pending.visible);
    return pending;
  }

  function sendOperation(pending, payload, onSettled) {
    var transport = global.CodexBridgeDesktopEmbeddedDSHTransport;
    pending.durable = true;
    pending.onSettled = onSettled;
    pending.payload = payload;
    var saved = persist();
    if (!saved) {
      pending.state = "failed"; pending.message = "无法保存发送状态，请检查应用本地存储。";
      changed(false); if (onSettled) onSettled(pending);
      return false;
    }
    if (!transport) {
      pending.state = "failed"; pending.message = "后台服务暂不可用，请重试。";
      changed(false); if (onSettled) onSettled(pending);
      return saved;
    }
    pending.inFlight = true;
    transport.call("operations.submit", {
      operationID: pending.requestID, requestID: pending.requestID,
      kind: pending.command === "resumeTask" ? "workbench.resume" : "workbench.steer",
      sessionID: pending.taskID, input: payload
    }, { timeoutMs: 10000 }).then(function (value) {
      pending.inFlight = false;
      applyOperation(pending, value);
    }, function () {
      pending.inFlight = false; pending.state = "checking"; changed(false); schedule(pending, 1000);
    });
    return saved;
  }

  function applyOperation(pending, response) {
    var values = response && response.operations;
    var operation = Array.isArray(values) && values.find(function (value) {
      return value.operationID === pending.requestID;
    });
    if (!operation && response && response.outcome === "notFound" && !pending.resubmitted && pending.payload) {
      pending.resubmitted = true; persist();
      sendOperation(pending, pending.payload, pending.onSettled); return;
    }
    if (!operation || ["recorded", "dispatching", "unknown"].indexOf(operation.phase) >= 0) {
      pending.state = "checking"; changed(false); schedule(pending); return;
    }
    if (["accepted", "completed"].indexOf(operation.phase) >= 0) {
      pending.state = "accepted"; pending.resultingTaskID = operation.resultTargetID || null;
      pending.message = "已发送";
    } else if (["failed", "cancelled"].indexOf(operation.phase) >= 0) {
      var failure = null;
      try { failure = JSON.parse(operation.resultJSON || "null"); } catch (_) {}
      pending.state = "failed";
      pending.message = failure && failure.message || "操作未完成，请重试。";
    } else {
      pending.state = "checking"; changed(false); schedule(pending); return;
    }
    pending.attempt = 0;
    changed(false);
    if (pending.onSettled) pending.onSettled(pending);
    else if (settled) settled(pending);
  }

  function schedule(pending, delay) {
    if (pending.timer || pending.inFlight) return;
    var attempt = Math.min(pending.attempt || 0, delays.length - 1);
    pending.attempt = attempt + 1;
    pending.timer = global.setTimeout(function () {
      pending.timer = null;
      if (global.document && global.document.visibilityState === "hidden") return;
      reconcile(pending);
    }, delay == null ? delays[attempt] : delay);
    if (pending.timer && pending.timer.unref) pending.timer.unref();
  }

  function reconcile(pending) {
    var transport = global.CodexBridgeDesktopEmbeddedDSHTransport;
    if (!transport || pending.inFlight || pending.state !== "checking") return;
    pending.inFlight = true;
    transport.call("operations.reconcile", { operationID: pending.requestID }, { timeoutMs: 10000 })
      .then(function (value) { pending.inFlight = false; applyOperation(pending, value); }, function () {
        pending.inFlight = false; schedule(pending);
      });
  }

  if (global.document) global.document.addEventListener("visibilitychange", function () {
    if (global.document.visibilityState === "hidden" || !refresh) return;
    submissions.forEach(function (pending) {
      if (pending.durable && pending.state === "checking") schedule(pending, 0);
    });
  });

  function queued(page) {
    return Array.from(submissions.values()).filter(function (pending) {
      return pending.durable && !pending.visible && pending.command === "steerTask"
        && ["sending", "checking", "accepted"].indexOf(pending.state) >= 0 && belongsToPage(pending, page);
    });
  }

  function acknowledge(page) {
    var receipt = page && page.commandReceipt;
    var pending = receipt && submissions.get(receipt.requestID);
    if (!pending || pending.state !== "sending" || !receipt.receiptID
      || receipt.receiptID === pending.baselineReceiptID
      || receipt.command !== pending.command || receipt.taskID !== pending.taskID
      || (receipt.input == null ? null : receipt.input) !== pending.input) return null;
    pending.state = receipt.accepted === true ? "accepted" : "failed";
    pending.message = receipt.message;
    pending.resultingTaskID = receipt.resultingTaskID;
    if (!pending.visible) submissions.delete(pending.requestID);
    changed(false);
    return pending;
  }

  function isPending(taskID) {
    return Array.from(submissions.values()).some(function (pending) {
      return ["sending", "checking"].indexOf(pending.state) >= 0
        && (pending.taskID === taskID || pending.resultingTaskID === taskID);
    });
  }

  function belongsToPage(pending, page) {
    var detail = page && page.selectedTask;
    return !!detail && pending.projectID === projectOf(page)
      && pending.providerID === detail.providerID
      && (pending.taskID === detail.taskID || pending.resultingTaskID === detail.taskID
        || (pending.sessionID !== pending.taskID && pending.sessionID === detail.sessionID));
  }

  function hasEntries(page) {
    return Array.from(submissions.values()).some(function (pending) {
      return pending.visible && belongsToPage(pending, page);
    });
  }

  function delivery(pending) {
    // Sent messages appear like native chat; only a failed delivery carries a note.
    var message = pending.state === "failed" ? "发送失败：" + (pending.message || "请重试") : "";
    return { deliveryState: pending.state, deliveryMessage: message };
  }

  function entries(values, page) {
    var result = values.slice(), claimed = new Set();
    submissions.forEach(function (pending, requestID) {
      if (!belongsToPage(pending, page)) return;
      var index = values.findIndex(function (entry) {
        return entry.role === "用户" && String(entry.text || "").trim() === pending.input.trim()
          && !pending.baselineIDs.has(entry.id) && !claimed.has(entry.id);
      });
      if (index >= 0) {
        claimed.add(values[index].id);
        if (pending.state === "accepted") {
          submissions.delete(requestID);
          revision += 1;
          persist();
        } else if (pending.state === "failed") {
          result[index] = Object.assign({}, result[index], delivery(pending));
        }
        return;
      }
      if (!pending.visible) return;
      result.push(Object.assign({
        id: "submission:" + requestID, role: "用户", kind: "message",
        text: pending.input, isFinal: true
      }, delivery(pending)));
    });
    return result;
  }

  global.CodexBridgeDesktopWorkbenchSubmissions = {
    bind: bind, begin: begin, acknowledge: acknowledge, isPending: isPending, newRequestID: newRequestID,
    sendOperation: sendOperation, queued: queued, setSettled: function (callback) { settled = callback; },
    entries: entries, hasEntries: hasEntries, revision: function () { return revision; }
  };
}(window));
