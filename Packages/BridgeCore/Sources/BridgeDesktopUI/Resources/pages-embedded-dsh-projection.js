(function (global) {
  "use strict";

  function textOf(value) {
    if (typeof value === "string") return value;
    if (Array.isArray(value)) return value.map(textOf).filter(Boolean).join("\n");
    if (!value || typeof value !== "object") return "";
    if (typeof value.text === "string") return value.text;
    if (typeof value.delta === "string") return value.delta;
    if (value.type === "image" || value.type === "file") {
      var name = value.attachment && value.attachment.name;
      return "[" + (value.type === "image" ? "图片" : "文件") + (typeof name === "string" ? "：" + name : "") + "]";
    }
    if (value.texts) return textOf(value.texts);
    if (value.stream) return textOf(value.stream);
    if (value.chunk) return textOf(value.chunk);
    if (value.content) return textOf(value.content);
    if (value.message) return textOf(value.message);
    return "";
  }

  function isUserInput(message) {
    var source = message && message.source;
    return !source || !source.kind || source.kind === "user" || source.kind === "user-rpc";
  }

  function projectJob(jobs, entries, id, event, data) {
    var jobID = data.jobId == null ? "event:" + id : String(data.jobId);
    var job = jobs.get(jobID);
    if (!job) {
      job = { id: "job:" + jobID, jobID: jobID, kind: "job", name: "后台任务", input: "", status: "运行中", sourceIDs: [] };
      jobs.set(jobID, job); entries.push(job);
    }
    job.sourceIDs.push(id);
    if (data.label) job.input = data.label;
    if (data.kind) job.name = "后台任务 · " + data.kind;
    if (data.toolCall) {
      if (data.toolCall.callId) job.callID = String(data.toolCall.callId);
      if (data.toolCall.rootCallId) job.rootCallID = String(data.toolCall.rootCallId);
    }
    if (event.type === "job/settled") {
      job.status = ({ completed: "已完成", failed: "失败", killed: "已停止" })[data.status] || data.status || "状态未知";
      job.detail = data.detail || "";
    }
  }

  function attachJobs(entries, tools) {
    return entries.filter(function (entry) {
      if (entry.kind !== "job") return true;
      var tool = tools.get(entry.callID) || tools.get(entry.rootCallID);
      if (!tool) return true;
      entry.showInput = entry.callID !== tool.callID;
      if (!tool.jobs) tool.jobs = [];
      tool.jobs.push(entry);
      return false;
    });
  }

  function project(records) {
    var entries = [], tools = new Map(), jobs = new Map();
    (records || []).forEach(function (record) {
      var event = record && (record.event || record), data = event && event.data || {};
      if (!event || !event.type) return;
      if (event.surfaceOp && event.surfaceOp.op === "replace") return;
      var id = String(event.seq == null ? entries.length : event.seq);
      var truncated = Array.isArray(event.truncatedFields) ? event.truncatedFields : [];
      function contentReference(field) {
        return truncated.includes(field) && Number.isSafeInteger(event.seq) ? { seq: event.seq, field: field } : null;
      }
      if (event.type === "user/message" || event.type === "assistant/message") {
        var message = data.message || data;
        if (event.type === "user/message" && !isUserInput(message)) return;
        var blocks = message.content || message;
        if (event.type === "assistant/message" && Array.isArray(blocks)) {
          var reasoning = textOf(blocks.filter(function (block) { return block.type === "reasoning"; }));
          if (reasoning) entries.push({ id: id + ":reasoning", kind: "reasoning", text: reasoning,
            contentRef: contentReference("reasoning") });
          blocks = blocks.filter(function (block) { return block.type !== "reasoning"; });
        }
        var content = textOf(blocks);
        if (!content && event.type === "assistant/message") content = stream({ activeAttempt: { stream: data.stream } }).text;
        if (content) entries.push({ id: id, kind: "message", role: event.type.indexOf("user/") === 0 ? "用户" : "助手", text: content,
          contentRef: contentReference("message.text") });
      } else if (event.type === "tool/call") {
        var callID = String(data.callId || data.toolCallId || id);
        var tool = { id: id, callID: callID, kind: "tool", name: data.name || "工具", input: data.arguments || data.input || "", output: "", status: "运行中",
          inputRef: contentReference("tool.input") };
        tools.set(callID, tool); entries.push(tool);
      } else if (event.type === "tool/result") {
        var result = data.message || data, toolResult = tools.get(String(result.toolCallId || data.callId || ""));
        if (toolResult) { toolResult.output = textOf(result.content || result); toolResult.status = data.error || result.error || result.isError ? "失败" : "已完成";
          toolResult.outputRef = contentReference("tool.output"); }
      } else if (event.type === "assistant/attempt") {
        var attempt = stream({ activeAttempt: { stream: data.stream } });
        if (attempt.reasoning) entries.push({ id: id + ":reasoning", kind: "reasoning", text: attempt.reasoning });
        if (attempt.text) entries.push({ id: id, kind: "message", role: "助手", text: attempt.text });
        if (attempt.reasoning || attempt.text) entries.push({ id: id + ":incomplete", kind: "status", text: "此次输出未完成" });
      } else if (event.type === "compaction/start") {
        entries.push({ id: id, kind: "status", text: "正在压缩上下文" });
      } else if (event.type === "compaction/end") {
        entries.push({ id: id, kind: "status", text: data.error ? "上下文压缩失败：" + data.error : "上下文压缩完成" });
      } else if (event.type === "plan/mode") {
        entries.push({ id: id, kind: "status", text: data.active ? "已进入计划模式" : "已退出计划模式" });
      } else if (event.type === "job/registered" || event.type === "job/settled") {
        projectJob(jobs, entries, id, event, data);
      } else if (event.type === "turn/end" && data.reason && (data.reason.kind || data.reason) !== "completed") {
        entries.push({ id: id, kind: "status", text: data.message || data.reason.kind || data.reason });
      }
    });
    return bounded(attachJobs(entries, tools));
  }
  function stream(snapshot) {
    var attempt = snapshot && snapshot.activeAttempt, records = attempt && attempt.stream;
    var blocks = new Map(), result = { text: "", reasoning: "" };
    function block(index, kind) {
      var key = kind + ":" + (index == null ? "default" : index);
      if (!blocks.has(key)) blocks.set(key, { type: kind, text: "" });
      return blocks.get(key);
    }
    function parts(values) { return Array.isArray(values) ? values.filter(function (value) { return typeof value === "string"; }).join("") : ""; }
    (Array.isArray(records) ? records : []).forEach(function (record) {
      if (!record || typeof record !== "object") return;
      if (record.type === "text-chunks") block(record.index, "text").text += parts(record.texts);
      else if (record.type === "reasoning-chunks") block(record.index, "reasoning").text += parts(record.texts);
      else if (record.type === "chunk" && record.chunk) {
        var chunk = record.chunk;
        if (chunk.type === "text-delta" && typeof chunk.text === "string") block(chunk.index, "text").text += chunk.text;
        else if (chunk.type === "reasoning-delta" && typeof chunk.text === "string") block(chunk.index, "reasoning").text += chunk.text;
        else if (chunk.type === "block-end" && chunk.block && ["text", "reasoning"].includes(chunk.block.type)
          && typeof chunk.block.text === "string") block(chunk.index, chunk.block.type).text = chunk.block.text;
      }
    });
    ["text", "reasoning"].forEach(function (kind) {
      result[kind] = Array.from(blocks.values()).filter(function (value) { return value.type === kind; })
        .map(function (value) { return value.text; }).filter(Boolean).join("\n");
    });
    return result;
  }

  function projectBridge(messages) {
    return bounded((messages || []).map(function (message, index) {
      var id = JSON.stringify([message.taskID || message.task_id || "", message.key || message.message_id || index]);
      if (message.kind === "tool_call") return {
        id: id, kind: "tool", name: message.tool_name || "工具", input: message.tool_arguments || "",
        output: message.content || "", status: message.tool_status === "failed" ? "失败" : message.final ? "已完成" : "运行中"
      };
      if (message.kind === "reasoning") return { id: id, kind: "reasoning", text: message.content || "", isFinal: message.final };
      return { id: id, kind: "message", role: message.kind === "user" || message.role === "user" ? "用户" : "助手",
        text: message.content || "", isFinal: message.final };
    }));
  }
  function bounded(entries) {
    entries.forEach(function (entry) {
      ["text", "input", "output", "detail"].forEach(function (key) {
        if (typeof entry[key] === "string" && entry[key].length > 32768) {
          entry[key] = entry[key].slice(0, 32768) + "\n…内容过长，已省略部分展示。";
        }
      });
      if (entry.jobs) bounded(entry.jobs);
    });
    return entries;
  }
  function hasRequest(records, requestID) {
    return (records || []).some(function (record) {
      var event = record && (record.event || record), data = event && event.data || {};
      var message = data.message || data, source = message.source || {};
      return event && event.type === "user/message" && (!event.surfaceOp || event.surfaceOp.op !== "replace")
        && isUserInput(message) && source.rpcId === requestID;
    });
  }
  function ownsJobView(job, origin, current) {
    return !!origin && origin.follow && job.projectID === current.projectID && origin.revision === current.revision
      && (current.sessionID === origin.sessionID || origin.sessionID === null && current.sessionID === job.sessionId);
  }

  function navigationIndex(items, selected) {
    var index = new Map();
    (Array.isArray(items) ? items : []).forEach(function (item) {
      if (!item || typeof item.sessionId !== "string"
        || item.projectID != null && typeof item.projectID !== "string") return;
      var title = item.title || item.name || item.projections && item.projections.values && item.projections.values.title;
      var row = { sessionId: item.sessionId, projectID: item.projectID || null };
      if (typeof title === "string") row.title = title.slice(0, 500);
      if (typeof item.parentSessionId === "string") row.parentSessionId = item.parentSessionId;
      if (item.origin === "subagent") row.origin = item.origin;
      if (item.archived) row.archived = true;
      index.set(row.sessionId, row);
    });
    Object.keys(selected || {}).forEach(function (project) {
      var id = selected[project];
      if (typeof id === "string" && id && !index.has(id)) index.set(id, { sessionId: id, projectID: project || null });
    });
    return Array.from(index.values());
  }
  global.CodexBridgeDesktopEmbeddedDSHProjection = { textOf: textOf, project: project, projectBridge: projectBridge,
    hasRequest: hasRequest, ownsJobView: ownsJobView, navigationIndex: navigationIndex };
}(window));
