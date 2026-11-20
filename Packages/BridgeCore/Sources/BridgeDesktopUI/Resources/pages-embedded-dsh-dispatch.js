(function (global) {
  "use strict";
  // Sends a composer message that mentions Agents (`@[名称]`) straight to those Agents as subtasks of the
  // conversation, bypassing the conversation model.
  var T = global.CodexBridgeDesktopEmbeddedDSHTransport, O = global.CodexBridgeDesktopEmbeddedDSHOperations;
  var A = global.CodexBridgeDesktopEmbeddedDSHAgentMentions;
  var idle = { active: false, blocked: false };
  var reconcileDelays = [500, 1000, 2000, 4000, 8000];
  // The same failures the prompt flow treats as "the request may have reached the service".
  var uncertainCodes = ["embedded_dsh_transport_timeout", "embedded_dsh_runtime", "service_unavailable"];

  function sleep(ms) { return new Promise(function (resolve) { global.setTimeout(resolve, ms); }); }

  function create(host) {
    var busy = false;

    function scope() {
      var context = host.context();
      return { sessionID: context.sessionID, projectID: context.projectID };
    }

    // What the composer should do with this text: `active` when it mentions Agents, `blocked` while it cannot be sent.
    function inspect(text, importedImages) {
      if (!A.hasToken(text)) return idle;
      var current = scope(), agents = host.directory.list(current);
      if (!agents) {
        host.directory.ensure(current);
        var failed = host.directory.status(current) === "failed";
        return { active: true, blocked: true, busy: busy, hint: failed ? "无法读取 Agent 列表，请稍后重试。" : "正在读取 Agent 列表…" };
      }
      var parsed = A.parse(text, agents);
      if (!parsed.targets.length || parsed.unknown.length) return { active: true, blocked: true, hint: "Agent 不可用，请重新选择。" };
      var names = parsed.targets.map(function (target) { return target.label; }).join("、");
      var info = { active: true, blocked: busy, busy: busy, parsed: parsed, text: text, names: names, hint: "将直接交给 " + names };
      if (!parsed.body) {
        info.blocked = true; info.hint = "请写明要交给 " + names + " 的任务。";
      } else if (importedImages > 0) {
        info.blocked = true; info.hint = "Agent 暂不能接收导入的图片，请移除后再发送。";
      }
      return info;
    }

    function outcomeOf(operationID, result) {
      var operation = O.snapshot(result, operationID), outcome = O.outcome(operation), reason = "";
      if (outcome === "failed" && operation.resultJSON) {
        try { reason = JSON.parse(operation.resultJSON).message || ""; } catch (_) {}
      }
      return { outcome: outcome === "unknown" ? "pending" : outcome, reason: reason };
    }

    // Asks the service again until the operation has an answer; false when it still has none.
    async function reconcile(operationID) {
      for (var attempt = 0; attempt < reconcileDelays.length; attempt++) {
        await sleep(reconcileDelays[attempt]);
        try {
          var result = outcomeOf(operationID, await T.call("operations.read", { operationIDs: [operationID] }));
          if (result.outcome === "pending") result = outcomeOf(operationID, await T.call("operations.reconcile", { operationID: operationID }));
          if (result.outcome !== "pending") return result;
        } catch (_) { /* the next attempt asks again */ }
      }
      return { outcome: "unconfirmed", reason: "" };
    }

    // One dispatch. A retry of the same draft reuses its identifiers while the first outcome is unknown,
    // so the service cannot start the task twice.
    async function dispatchOne(projectID, sessionID, target, body, paths) {
      var key = JSON.stringify([target.agent.installationID, body, paths]);
      var attempt = host.attempt(projectID, sessionID, key, target.agent.name);
      var input = { sessionId: sessionID, childId: attempt.childID, operation: "dispatch", requestId: attempt.operationID,
        installationID: target.agent.installationID, text: body, label: attempt.label };
      if (paths.length) input.attachmentPaths = paths;
      var result;
      try {
        result = outcomeOf(attempt.operationID, await T.call("operations.submit", { operationID: attempt.operationID,
          kind: "subagents.control", sessionID: sessionID, childID: attempt.childID, requestID: attempt.operationID, input: input },
        { timeoutMs: 10000 }));
        if (result.outcome === "pending") result = await reconcile(attempt.operationID);
      } catch (error) {
        if (error && error.code && uncertainCodes.indexOf(error.code) < 0) result = { outcome: "failed", reason: error.message || "" };
        else result = await reconcile(attempt.operationID);
      }
      return { target: target, outcome: result.outcome, reason: result.reason, key: key };
    }

    function failureMessage(results) {
      return results.map(function (result) {
        var name = result.target.label;
        if (result.outcome === "unconfirmed") return name + " 的交付结果尚未确认，请在 Agent 列表核对后再试。";
        return "未能交给 " + name + (result.reason ? "：" + result.reason : "，请重试。");
      }).join("\n");
    }

    function finish(info, results, sessionID) {
      busy = false;
      // The composer only changes while it still shows the conversation the message came from.
      var here = scope().sessionID === sessionID;
      var failed = results.filter(function (result) { return result.outcome !== "accepted"; });
      var settled = results.filter(function (result) { return result.outcome !== "unconfirmed"; }).map(function (result) { return result.key; });
      if (!failed.length) { if (here) { host.finish("", true, settled); host.setMessage(""); } return; }
      var kept = new Set(failed.map(function (result) { return result.target.agent.installationID; }));
      if (!here) return;
      // Marks of the Agents that took the task go; the others stay so a retry only reaches them.
      host.finish(A.cut(info.text, info.parsed.tokens, function (token) { return !kept.has(token.agent.installationID); }), false, settled);
      host.setMessage(failureMessage(failed));
    }

    function run(info) {
      var captured = host.capture();
      busy = true; host.setMessage("正在交给 " + info.names + "…");
      return host.ensureSession().then(function (sessionID) {
        return Promise.all(info.parsed.targets.map(function (target) {
          return dispatchOne(captured.projectID, sessionID, target, info.parsed.body, captured.paths);
        })).then(function (results) { finish(info, results, sessionID); });
      }).catch(function (error) {
        busy = false; host.setMessage(error && error.message || "未能交给 Agent，请重试。");
      });
    }

    // True when the text is a message to Agents: it was sent, or it is not ready to send (the composer shows why).
    function submit(text, importedImages) {
      var info = inspect(text, importedImages);
      if (!info.active) return false;
      if (!info.blocked) run(info);
      return true;
    }

    return { inspect: inspect, submit: submit, busy: function () { return busy; } };
  }

  var api = { create: create };
  global.CodexBridgeDesktopEmbeddedDSHDispatch = api;
  if (typeof module !== "undefined" && module.exports) module.exports = api;
}(typeof window === "undefined" ? globalThis : window));
