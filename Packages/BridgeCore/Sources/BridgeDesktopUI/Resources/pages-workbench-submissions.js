(function (global) {
  "use strict";
  var submissions = new Map(), revision = 0, refresh = null, sequence = 0;

  function newRequestID() {
    sequence += 1;
    return "workbench-" + Date.now().toString(36) + "-" + sequence + "-"
      + Math.random().toString(36).slice(2, 10);
  }

  function bind(page, onChange) {
    refresh = page ? onChange : null;
  }

  function changed(follow) {
    revision += 1;
    if (refresh) refresh(follow);
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
      projectID: page && page.selectedProjectID,
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
      return pending.state === "sending"
        && (pending.taskID === taskID || pending.resultingTaskID === taskID);
    });
  }

  function belongsToPage(pending, page) {
    var detail = page && page.selectedTask;
    return !!detail && pending.projectID === page.selectedProjectID
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
    var message = pending.state === "sending" ? "发送中…" : "已发送";
    if (pending.state === "failed") message = "发送失败：" + (pending.message || "请重试");
    return { deliveryState: pending.state, deliveryMessage: message };
  }

  function entries(values, page) {
    var result = values.slice(), claimed = new Set();
    submissions.forEach(function (pending, requestID) {
      if (!pending.visible || !belongsToPage(pending, page)) return;
      var index = values.findIndex(function (entry) {
        return entry.role === "用户" && String(entry.text || "").trim() === pending.input.trim()
          && !pending.baselineIDs.has(entry.id) && !claimed.has(entry.id);
      });
      if (index >= 0) {
        claimed.add(values[index].id);
        if (pending.state === "accepted") {
          submissions.delete(requestID);
          revision += 1;
        } else if (pending.state === "failed") {
          result[index] = Object.assign({}, result[index], delivery(pending));
        }
        return;
      }
      result.push(Object.assign({
        id: "submission:" + requestID, role: "用户", kind: "message",
        text: pending.input, isFinal: true
      }, delivery(pending)));
    });
    return result;
  }

  global.CodexBridgeDesktopWorkbenchSubmissions = {
    bind: bind, begin: begin, acknowledge: acknowledge, isPending: isPending, newRequestID: newRequestID,
    entries: entries, hasEntries: hasEntries, revision: function () { return revision; }
  };
}(window));
