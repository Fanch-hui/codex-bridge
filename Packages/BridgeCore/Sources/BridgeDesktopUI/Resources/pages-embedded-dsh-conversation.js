(function (global) {
  "use strict";
  var S = global.CodexBridgeDesktopPageSupport;
  var P = global.CodexBridgeDesktopEmbeddedDSHProjection;
  var C = global.CodexBridgeDesktopWorkbenchConversation;
  var M = global.CodexBridgeDesktopEmbeddedDSHMarkdown;
  var Metrics = global.CodexBridgeDesktopEmbeddedDSHMetrics;

  // Tool arguments are re-projected from the same history records on every render, so objects are
  // formatted once and remembered by reference; primitives are cheap and formatted directly.
  var formattedObjects = new WeakMap();
  function formatValue(value) {
    var text;
    if (typeof value === "string") text = value;
    else { try { text = JSON.stringify(value, null, 2); } catch (_) { text = String(value); } }
    return text.length > 32768 ? text.slice(0, 32768) + "\n…内容过长，已省略部分展示。" : text;
  }
  function stringify(value) {
    if (value == null) return "";
    if (typeof value !== "object") return formatValue(value);
    var text = formattedObjects.get(value);
    if (text === undefined) { text = formatValue(value); formattedObjects.set(value, text); }
    return text;
  }

  function jobDetails(entry) {
    var jobs = entry.kind === "job" ? [entry] : entry.jobs || [];
    return jobs.map(function (job) {
      var title = "后台任务" + (jobs.length > 1 ? " " + job.jobID : "") + " · " + job.status;
      return [title, job.showInput ? stringify(job.input) : "", stringify(job.detail)].filter(Boolean).join("\n");
    }).join("\n\n");
  }

  function toolStatus(entry) {
    var jobs = entry.jobs || [];
    if (entry.status === "失败" || jobs.some(function (job) { return job.status === "失败"; })) return "failed";
    if (entry.status === "运行中" || jobs.some(function (job) { return job.status === "运行中"; })) return "running";
    if (entry.status === "已完成") return "completed";
    if (entry.status === "已停止") return "cancelled";
    return "running";
  }

  function number(value) { return typeof value === "number" && Number.isFinite(value) && value >= 0; }
  function edgeBlur(bottom) {
    var node = S.node("div", bottom ? "workbench-edge-blur is-bottom dsh-bridge-edge-blur" : "workbench-edge-blur dsh-bridge-edge-blur");
    node.setAttribute("aria-hidden", "true");
    for (var i = 0; i < 5; i++) node.appendChild(S.node("span"));
    return node;
  }
  function create(configuration) {
    configuration = configuration || {};
    var root = S.node("section", "dsh-embedded-conversation dsh-bridge-conversation");
    var viewport = S.node("div", "dsh-bridge-conversation-scroll");
    viewport.setAttribute("role", "log"); viewport.setAttribute("aria-label", "工作台对话");
    var earlier = S.button("加载更早的消息", null, null, null, "small dsh-bridge-earlier");
    var newer = S.button("查看较新消息", null, null, null, "small dsh-bridge-earlier");
    var empty = S.node("div", "dsh-chat-empty"), emptyText = S.node("h3", "dsh-chat-empty-title", "想完成什么？");
    var list = S.node("div", "dsh-chat-conversation"), metrics = Metrics.create();
    empty.appendChild(emptyText); viewport.appendChild(earlier); viewport.appendChild(empty); viewport.appendChild(list); viewport.appendChild(newer);
    root.appendChild(viewport); root.appendChild(edgeBlur(false)); root.appendChild(edgeBlur(true)); root.appendChild(metrics.root);
    var nodes = new Map(), markdown = new Map(), positions = new Map(), sessionID, options = {}, following = true, pendingPosition = null;
    var contentReader = global.CodexBridgeDesktopEmbeddedDSHContent && global.CodexBridgeDesktopEmbeddedDSHContent.create();
    if (contentReader) root.appendChild(contentReader.root);
    var windowStart = null, lastEntries = [], lastDisplayEntries = [], lastProjectTitle = "", windowSize = 200;
    function updateMetricsGeometry() {
      var area = root.getBoundingClientRect(), footer = metrics.root.getBoundingClientRect();
      root.style.setProperty("--bridge-metrics-height", Math.ceil(footer.height) + "px");
      root.style.setProperty("--bridge-metrics-top", Math.max(0, Math.floor(footer.top - area.top)) + "px");
      metrics.position();
      if (following && !pendingPosition) viewport.scrollTop = viewport.scrollHeight;
    }
    var metricsObserver = typeof global.ResizeObserver === "function" ? new global.ResizeObserver(updateMetricsGeometry) : null;
    if (metricsObserver) { metricsObserver.observe(root); metricsObserver.observe(metrics.root); }

    earlier.addEventListener("click", function () {
      if (windowStart > 0) {
        following = false; windowStart = Math.max(0, windowStart - Math.floor(windowSize / 2));
        render(sessionID, lastProjectTitle, lastEntries); return;
      }
      if (!earlier.disabled && typeof options.onLoadEarlier === "function") options.onLoadEarlier();
    });
    newer.addEventListener("click", function () {
      following = false; windowStart = Math.min(Math.max(0, lastEntries.length - windowSize), windowStart + Math.floor(windowSize / 2));
      render(sessionID, lastProjectTitle, lastEntries);
    });
    viewport.addEventListener("scroll", function () {
      following = viewport.scrollHeight - viewport.clientHeight - viewport.scrollTop < 48;
    });

    function entryValue(entry, key) {
      var contentActions = entry.kind === "tool" ? [
        { ref: entry.inputRef, title: "查看完整输入" }, { ref: entry.outputRef, title: "查看完整输出" }
      ] : [{ ref: entry.contentRef, title: "查看完整" }];
      contentActions = contentActions.filter(function (value) { return value.ref; });
      if (entry.kind === "tool" || entry.kind === "job") return {
        id: entry.id, kind: "tool_call", toolName: entry.name, toolArguments: stringify(entry.input),
        text: stringify(entry.output), jobDetails: jobDetails(entry), contentActions: contentActions,
        toolStatus: toolStatus(entry),
        displayStatus: entry.kind === "job" ? entry.status : undefined, isFinal: entry.status !== "运行中"
      };
      var content = stringify(entry.text), cache;
      if (!global.CodexBridgeDesktopDSHConversationView) {
        cache = markdown.get(key);
        if (!cache || cache.text !== content) {
          cache = { text: content, html: M.render(content) }; markdown.set(key, cache);
        }
      }
      return { id: entry.id, kind: entry.kind === "reasoning" ? "reasoning" : "message",
        role: entry.role || "助手", text: content, markdownHTML: cache && cache.html,
        isFinal: entry.isFinal !== false, contentActions: contentActions };
    }

    function updateContentActions(item, entry, id) {
      if (!contentReader) return;
      var values = entry.kind === "tool" ? [
        { ref: entry.inputRef, title: "查看完整输入" }, { ref: entry.outputRef, title: "查看完整输出" }
      ] : [{ ref: entry.contentRef, title: "查看完整" }];
      values = values.filter(function (value) { return value.ref; });
      if (!values.length) { if (item.__fullContent) item.__fullContent.remove(); item.__fullContent = null; return; }
      var holder = item.__fullContent || (item.__fullContent = S.node("div", "dsh-full-content-actions"));
      var signature = JSON.stringify(values);
      if (holder.__signature !== signature) {
        holder.__signature = signature; S.clear(holder);
        values.forEach(function (value) {
          var button = S.button(value.title, null, {}, null, "small");
          button.addEventListener("click", function () { contentReader.open(id, value.ref); }); holder.appendChild(button);
        });
      }
      var parent = item.__body || item;
      if (holder.parentNode !== parent) parent.appendChild(holder);
    }

    function update(id, projectTitle, records, streamText, pending, streamReasoning, nextOptions) {
      options = nextOptions || {};
      var entries = P.project(records);
      (Array.isArray(pending) ? pending : pending ? [pending] : []).forEach(function (item) {
        if (P.hasRequest(records, item.requestId)) return;
        var attachments = (item.attachmentRefs || []).length + (item.attachmentPaths || []).length;
        var text = [item.text, attachments ? "[图片 × " + attachments + "]" : ""].filter(Boolean).join("\n");
        entries.push({ id: "pending:" + item.requestId, kind: "message", role: "用户", text: text });
      });
      if (streamReasoning) entries.push({ id: "stream-reasoning", kind: "reasoning", text: streamReasoning, isFinal: false });
      if (streamText) entries.push({ id: "stream", kind: "message", role: "助手", text: streamText, isFinal: false });
      var callIDs = new Set(entries.filter(function (entry) { return entry.kind === "tool"; }).map(function (entry) { return entry.callID; }));
      (Array.isArray(options.streamTools) ? options.streamTools : []).forEach(function (tool) {
        if (!tool || !tool.id || callIDs.has(tool.id)) return;
        entries.push({ id: "stream:" + tool.id, callID: tool.id, kind: "tool", name: tool.name || "工具", input: tool.input, status: "运行中" });
      });
      if (options.running && !streamText && !streamReasoning) entries.push({ id: "running", kind: "status", text: "正在处理…" });
      render(id, projectTitle, entries);
    }

    function groupProcessEntries(entries) {
      var Process = global.CodexBridgeDesktopWorkbenchProcess;
      if (!Process) return entries;
      var result = [], turn = [];
      function flushTurn(completed) {
        if (!turn.length) return;
        var hasProcess = turn.some(function (entry) { return entry.kind === "reasoning" || entry.kind === "tool" || entry.kind === "job"; });
        var hasRunningTool = turn.some(function (entry) {
          return (entry.kind === "tool" || entry.kind === "job") &&
            (entry.status === "运行中" || (entry.jobs || []).some(function (job) { return job.status === "运行中"; }));
        });
        if (!completed || !hasProcess || hasRunningTool) {
          turn.forEach(function (entry) { result.push(entry); });
          turn = [];
          return;
        }
        // Only consecutive reasoning and tool steps fold; the model's replies between them stay
        // visible in order, so intermediate updates are read like the final answer.
        var run = [];
        function flushRun() {
          if (run.length) result.push({ id: String(run[0].id), kind: "process", rawEntries: run });
          run = [];
        }
        turn.forEach(function (entry) {
          if (entry.kind === "reasoning" || entry.kind === "tool" || entry.kind === "job") run.push(entry);
          else { flushRun(); result.push(entry); }
        });
        flushRun();
        turn = [];
      }
      entries.forEach(function (entry) {
        if (entry.kind === "message" && entry.role === "用户") {
          flushTurn(true);
          result.push(entry);
        } else {
          turn.push(entry);
        }
      });
      var lastTurnCompleted = !options.running && !turn.some(function (entry) {
        return entry.id === "stream" || entry.id === "stream-reasoning" || entry.id === "running" || entry.isFinal === false;
      });
      flushTurn(lastTurnCompleted);
      return result;
    }

    function render(id, projectTitle, entries) {
      var changed = id !== sessionID, oldHeight = viewport.scrollHeight, oldTop = viewport.scrollTop;
      var previousFirst = list.firstElementChild;
      var positionForSession = changed && id != null ? positions.get(id) : null;
      metrics.setSession(id, configuration.contextSettings !== false && options.contextSettings !== false);
      if (changed) {
        metrics.close();
        if (sessionID != null) positions.set(sessionID, pendingPosition || { top: oldTop, following: following });
        nodes.forEach(function (item) {
          if (item.__dshHost) global.CodexBridgeDesktopDSHConversationView.dispose(item);
        });
        nodes.clear(); markdown.clear(); S.clear(list); sessionID = id; previousFirst = null; windowStart = null;
        following = !positionForSession || positionForSession.following;
        pendingPosition = positionForSession && !following ? positionForSession : null;
      }
      lastEntries = entries; lastProjectTitle = projectTitle;
      var displayEntries = groupProcessEntries(entries);
      lastDisplayEntries = displayEntries;
      if (windowStart === null || following && !pendingPosition) windowStart = Math.max(0, displayEntries.length - windowSize);
      windowStart = Math.min(windowStart, Math.max(0, displayEntries.length - windowSize));
      var visibleEntries = displayEntries.slice(windowStart, windowStart + windowSize);
      var used = new Set(), position = list.firstElementChild;
      visibleEntries.forEach(function (entry) {
        var key = entry.kind + ":" + entry.id, item = nodes.get(key);
        var upstream = global.CodexBridgeDesktopDSHConversationView;
        function openContent(ref) { if (contentReader) contentReader.open(id, ref); }
        if (entry.kind === "status") {
          if (upstream) {
            var status = { id: entry.id, kind: "status", text: entry.text, running: entry.id === "running" };
            if (!item) { item = upstream.create(status, id); nodes.set(key, item); }
            else upstream.update(item, status, id);
          } else {
            if (!item) { item = S.node("div", "dsh-bridge-conversation-status"); item.setAttribute("role", "status"); nodes.set(key, item); }
            if (item.textContent !== entry.text) item.textContent = entry.text;
          }
        } else if (entry.kind === "process") {
          var processValues = entry.rawEntries.map(function (subEntry) {
            var subValue = entryValue(subEntry, subEntry.kind + ":" + subEntry.id);
            if (!upstream) subValue.__rawEntry = subEntry;
            return subValue;
          });
          var processEntry = {
            id: "process:" + entry.id,
            kind: "process",
            processEntries: processValues,
            onOpenContent: openContent,
            onRenderChild: function (childNode, childValue) {
              if (childValue.__rawEntry) updateContentActions(childNode, childValue.__rawEntry, id);
            }
          };
          if (!item) {
            item = global.CodexBridgeDesktopWorkbenchProcess.create(processEntry, id);
            nodes.set(key, item);
          } else {
            global.CodexBridgeDesktopWorkbenchProcess.update(item, processEntry);
          }
        } else {
          var value = entryValue(entry, key);
          if (upstream) {
            if (!item) { item = upstream.create(value, id, openContent); nodes.set(key, item); }
            else upstream.update(item, value, id, openContent);
          } else if (!item) {
            item = value.kind === "message" ? C.createMessage(value) : C.createDisclosure(value, id);
            nodes.set(key, item);
          } else if (value.kind === "message") C.updateMessage(item, value);
          else C.updateDisclosure(item, value, id);
          if (!upstream) updateContentActions(item, entry, id);
        }
        used.add(key);
        if (item === position) position = position.nextElementSibling;
        else if (position) list.insertBefore(item, position);
        else list.appendChild(item);
      });
      nodes.forEach(function (item, key) {
        if (!used.has(key)) {
          if (item.__dshHost) global.CodexBridgeDesktopDSHConversationView.dispose(item);
          item.remove(); nodes.delete(key); markdown.delete(key);
        }
      });
      empty.hidden = displayEntries.length > 0;
      emptyText.textContent = projectTitle ? "想在 " + projectTitle + " 中完成什么？" : "想完成什么？";
      list.hidden = displayEntries.length === 0;
      earlier.hidden = windowStart === 0 && !options.hasMore && !options.loadingEarlier;
      earlier.disabled = !!options.loadingEarlier;
      earlier.textContent = options.loadingEarlier ? "正在加载更早消息…" : "加载更早的消息";
      newer.hidden = windowStart + windowSize >= displayEntries.length;
      metrics.update(options.projections);
      var hasContent = displayEntries.some(function (entry) { return entry.kind !== "status"; });
      if (pendingPosition && hasContent) { following = false; viewport.scrollTop = pendingPosition.top; pendingPosition = null; }
      else if (!pendingPosition && (changed || following)) viewport.scrollTop = viewport.scrollHeight;
      else if (previousFirst && list.firstElementChild !== previousFirst) viewport.scrollTop = oldTop + viewport.scrollHeight - oldHeight;
    }

    return {
      root: root, update: update,
      updateBridge: function (id, messages, nextOptions) {
        options = nextOptions || {}; options.contextSettings = false;
        render(id, "", P.projectBridge(messages));
      },
      receive: function (item) { metrics.receive(item); },
      setBottomInset: function (value) {
        root.style.setProperty("--bridge-conversation-inset", (number(value) ? value : 0) + "px");
        if (metricsObserver) updateMetricsGeometry();
      },
      revealSequence: function (seq) {
        if (!Number.isSafeInteger(seq)) return false;
        var target = String(seq);
        function containsSequence(entry) {
          if (String(entry.id).split(":")[0] === target || (entry.sourceIDs || []).includes(target)) return true;
          return (entry.jobs || []).some(function (job) { return job.sourceIDs.includes(target); });
        }
        var index = lastDisplayEntries.findIndex(function (entry) {
          if (containsSequence(entry)) return true;
          return entry.kind === "process" && entry.rawEntries.some(function (subEntry) {
            return containsSequence(subEntry);
          });
        });
        if (index < 0) return false;
        following = false; pendingPosition = null;
        windowStart = Math.max(0, Math.min(index - 20, Math.max(0, lastDisplayEntries.length - windowSize)));
        render(sessionID, lastProjectTitle, lastEntries);
        var entry = lastDisplayEntries[index], item = nodes.get(entry.kind + ":" + entry.id);
        if (item && entry.kind === "process") {
          if (item.__dshHost) global.CodexBridgeDesktopDSHConversationView.reveal(item);
          else item.open = true;
        }
        if (item && item.scrollIntoView) item.scrollIntoView({ block: "center" });
        return !!item;
      },
      dispose: function () {
        nodes.forEach(function (item) { if (item.__dshHost) global.CodexBridgeDesktopDSHConversationView.dispose(item); });
        nodes.clear();
        if (metricsObserver) metricsObserver.disconnect(); metrics.dispose(); if (contentReader) contentReader.dispose();
      }
    };
  }
  global.CodexBridgeDesktopEmbeddedDSHConversation = { create: create };
}(window));
