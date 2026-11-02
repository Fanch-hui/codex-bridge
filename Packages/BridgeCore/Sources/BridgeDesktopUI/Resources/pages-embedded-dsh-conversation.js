(function (global) {
  "use strict";
  var S = global.CodexBridgeDesktopPageSupport;
  var P = global.CodexBridgeDesktopEmbeddedDSHProjection;
  var C = global.CodexBridgeDesktopWorkbenchConversation;
  var M = global.CodexBridgeDesktopEmbeddedDSHMarkdown;
  var Metrics = global.CodexBridgeDesktopEmbeddedDSHMetrics;

  function stringify(value) {
    if (value == null) return "";
    var text;
    if (typeof value === "string") text = value;
    else { try { text = JSON.stringify(value, null, 2); } catch (_) { text = String(value); } }
    return text.length > 32768 ? text.slice(0, 32768) + "\n…内容过长，已省略部分展示。" : text;
  }

  function number(value) { return typeof value === "number" && Number.isFinite(value) && value >= 0; }
  function create() {
    var root = S.node("section", "dsh-embedded-conversation dsh-bridge-conversation");
    var viewport = S.node("div", "dsh-bridge-conversation-scroll");
    viewport.setAttribute("role", "log"); viewport.setAttribute("aria-label", "工作台对话");
    var earlier = S.button("加载更早的消息", null, null, null, "small dsh-bridge-earlier");
    var newer = S.button("查看较新消息", null, null, null, "small dsh-bridge-earlier");
    var empty = S.node("div", "dsh-chat-empty"), emptyText = S.node("h3", "dsh-chat-empty-title", "想完成什么？");
    var list = S.node("div", "dsh-chat-conversation"), metrics = Metrics.create();
    empty.appendChild(emptyText); viewport.appendChild(earlier); viewport.appendChild(empty); viewport.appendChild(list); viewport.appendChild(newer);
    root.appendChild(viewport); root.appendChild(metrics.root);
    var nodes = new Map(), markdown = new Map(), positions = new Map(), sessionID, options = {}, following = true, pendingPosition = null;
    var contentReader = global.CodexBridgeDesktopEmbeddedDSHContent && global.CodexBridgeDesktopEmbeddedDSHContent.create();
    if (contentReader) root.appendChild(contentReader.root);
    var windowStart = null, lastEntries = [], lastProjectTitle = "", windowSize = 200;
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
      if (entry.kind === "tool") return {
        id: entry.id, kind: "tool_call", toolName: entry.name, toolArguments: stringify(entry.input),
        text: stringify(entry.output), toolStatus: entry.status === "失败" ? "failed"
          : entry.status === "已完成" ? "completed" : "running", isFinal: entry.status !== "运行中"
      };
      var content = stringify(entry.text), cache = markdown.get(key);
      if (!cache || cache.text !== content) {
        cache = { text: content, html: M.render(content) }; markdown.set(key, cache);
      }
      return { id: entry.id, kind: entry.kind === "reasoning" ? "reasoning" : "message",
        role: entry.role || "助手", text: content, markdownHTML: cache.html, isFinal: entry.isFinal !== false };
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

    function render(id, projectTitle, entries) {
      var changed = id !== sessionID, oldHeight = viewport.scrollHeight, oldTop = viewport.scrollTop;
      var previousFirst = list.firstElementChild;
      var positionForSession = changed && id != null ? positions.get(id) : null;
      if (changed) {
        metrics.close();
        if (sessionID != null) positions.set(sessionID, pendingPosition || { top: oldTop, following: following });
        nodes.clear(); markdown.clear(); S.clear(list); sessionID = id; previousFirst = null; windowStart = null;
        following = !positionForSession || positionForSession.following;
        pendingPosition = positionForSession && !following ? positionForSession : null;
      }
      lastEntries = entries; lastProjectTitle = projectTitle;
      if (windowStart === null || following && !pendingPosition) windowStart = Math.max(0, entries.length - windowSize);
      windowStart = Math.min(windowStart, Math.max(0, entries.length - windowSize));
      var visibleEntries = entries.slice(windowStart, windowStart + windowSize);
      var used = new Set(), position = list.firstElementChild;
      visibleEntries.forEach(function (entry) {
        var key = entry.kind + ":" + entry.id, item = nodes.get(key);
        if (entry.kind === "status") {
          if (!item) { item = S.node("div", "dsh-bridge-conversation-status"); item.setAttribute("role", "status"); nodes.set(key, item); }
          if (item.textContent !== entry.text) item.textContent = entry.text;
        } else {
          var value = entryValue(entry, key);
          if (!item) {
            item = value.kind === "message" ? C.createMessage(value) : C.createDisclosure(value, id);
            nodes.set(key, item);
          } else if (value.kind === "message") C.updateMessage(item, value);
          else C.updateDisclosure(item, value, id);
          updateContentActions(item, entry, id);
        }
        used.add(key);
        if (item === position) position = position.nextElementSibling;
        else if (position) list.insertBefore(item, position);
        else list.appendChild(item);
      });
      nodes.forEach(function (item, key) {
        if (!used.has(key)) { item.remove(); nodes.delete(key); markdown.delete(key); }
      });
      empty.hidden = entries.length > 0;
      emptyText.textContent = projectTitle ? "想在 " + projectTitle + " 中完成什么？" : "想完成什么？";
      list.hidden = entries.length === 0;
      earlier.hidden = windowStart === 0 && !options.hasMore && !options.loadingEarlier;
      earlier.disabled = !!options.loadingEarlier;
      earlier.textContent = options.loadingEarlier ? "正在加载更早消息…" : "加载更早的消息";
      newer.hidden = windowStart + windowSize >= entries.length;
      metrics.update(options.projections);
      var hasContent = entries.some(function (entry) { return entry.kind !== "status"; });
      if (pendingPosition && hasContent) { following = false; viewport.scrollTop = pendingPosition.top; pendingPosition = null; }
      else if (!pendingPosition && (changed || following)) viewport.scrollTop = viewport.scrollHeight;
      else if (previousFirst && list.firstElementChild !== previousFirst) viewport.scrollTop = oldTop + viewport.scrollHeight - oldHeight;
    }

    return {
      root: root, update: update,
      updateBridge: function (id, messages) { options = {}; render(id, "", P.projectBridge(messages)); },
      setBottomInset: function (value) {
        root.style.setProperty("--bridge-conversation-inset", (number(value) ? value : 0) + "px");
        if (metricsObserver) updateMetricsGeometry();
      },
      revealSequence: function (seq) {
        if (!Number.isSafeInteger(seq)) return false;
        var index = lastEntries.findIndex(function (entry) { return String(entry.id).split(":")[0] === String(seq); });
        if (index < 0) return false;
        following = false; pendingPosition = null;
        windowStart = Math.max(0, Math.min(index - 20, Math.max(0, lastEntries.length - windowSize)));
        render(sessionID, lastProjectTitle, lastEntries);
        var entry = lastEntries[index], item = nodes.get(entry.kind + ":" + entry.id);
        if (item && item.scrollIntoView) item.scrollIntoView({ block: "center" });
        return !!item;
      },
      dispose: function () { if (metricsObserver) metricsObserver.disconnect(); metrics.dispose(); if (contentReader) contentReader.dispose(); }
    };
  }
  global.CodexBridgeDesktopEmbeddedDSHConversation = { create: create };
}(window));
