(function (global) {
  "use strict";
  var S = global.CodexBridgeDesktopPageSupport;
  var symbols = {
    activity: '<path d="M4 14a8 8 0 1 1 16 0"/><path d="m12 12 4-4"/><path d="M5.5 17h13"/>',
    usage: '<ellipse cx="12" cy="5" rx="8" ry="3"/><path d="M4 5v7c0 1.7 3.6 3 8 3s8-1.3 8-3V5M4 12v7c0 1.7 3.6 3 8 3s8-1.3 8-3v-7"/>',
    context: '<circle cx="12" cy="12" r="8" opacity=".25"/>'
  };

  function number(value) { return typeof value === "number" && Number.isFinite(value) && value >= 0; }
  function compact(value) {
    if (value < 1000) return String(value);
    if (value < 1000000) return (value / 1000).toFixed(value < 10000 ? 1 : 0).replace(/\.0$/, "") + "K";
    return (value / 1000000).toFixed(value < 10000000 ? 1 : 0).replace(/\.0$/, "") + "M";
  }
  function exact(value) { return Math.round(value).toLocaleString() + " tok"; }
  function duration(ms) {
    if (ms < 1000) return Math.round(ms) + " ms";
    if (ms < 60000) return (ms / 1000).toFixed(ms < 10000 ? 1 : 0).replace(/\.0$/, "") + " 秒";
    var minutes = Math.floor(ms / 60000), seconds = Math.round((ms % 60000) / 1000);
    if (seconds === 60) { minutes += 1; seconds = 0; }
    return minutes + " 分" + (seconds ? " " + seconds + " 秒" : "");
  }
  function matchesModel(policy, selectedModel) {
    var model = policy && policy.modelSelection;
    return !selectedModel || !model || model.provider === selectedModel.provider && model.model === selectedModel.model;
  }
  function eligiblePolicy(policy, selectedModel, minimumRevision) {
    return policy && matchesModel(policy, selectedModel)
      && (!number(minimumRevision) || number(policy.revision) && policy.revision >= minimumRevision);
  }
  function newestPolicy(projected, loaded) {
    if (!loaded) return projected;
    if (!projected) return loaded;
    if (number(projected.revision) && number(loaded.revision) && projected.revision > loaded.revision) return projected;
    return loaded;
  }
  function values(projections, loadedPolicy, sessionAvailable, selectedModel, minimumRevision) {
    var source = projections && projections.values || {};
    var stats = source.sessionStats || {}, usage = source.tokenUsage || {};
    var pressure = source.contextPressure || {}, breakdown = source.contextBreakdown || {};
    var projectedPolicy = eligiblePolicy(source.contextPolicy, selectedModel, minimumRevision) ? source.contextPolicy : null;
    var loaded = eligiblePolicy(loadedPolicy, selectedModel, minimumRevision) ? loadedPolicy : null;
    var policy = newestPolicy(projectedPolicy, loaded), effective = policy && policy.effective || {};
    var stalePressure = !policy && (source.contextPolicy && !projectedPolicy || minimumRevision > 0);
    var result = {};
    if (number(stats.steps) && stats.steps > 0) {
      var speed = number(stats.decodeTokens) && number(stats.decodeMs) && stats.decodeMs > 0
        ? Math.round(stats.decodeTokens * 1000 / stats.decodeMs) + " tok/s" : null;
      var activity = [["执行步骤", String(stats.steps)]];
      if (number(stats.llmMs) && stats.llmMs > 0) activity.push(["模型耗时", duration(stats.llmMs)]);
      if (number(stats.toolMs) && stats.toolMs > 0) activity.push(["工具耗时", duration(stats.toolMs)]);
      if (number(stats.ttftMs) && number(stats.ttftSteps) && stats.ttftSteps > 0) {
        activity.push(["平均首字耗时", duration(stats.ttftMs / stats.ttftSteps)]);
      }
      if (speed) activity.push(["生成速度", speed]);
      result.activity = { label: stats.steps + " 步" + (speed ? " · " + speed : ""), title: "运行统计", rows: activity };
    }
    var buckets = [usage.uncachedInputTokens, usage.outputTokens, usage.cacheReadTokens, usage.cacheWriteTokens];
    if (buckets.every(number)) {
      var total = buckets.reduce(function (sum, value) { return sum + value; }, 0);
      var input = usage.uncachedInputTokens + usage.cacheReadTokens + usage.cacheWriteTokens;
      if (total > 0) {
        var hit = input ? Math.round(usage.cacheReadTokens * 100 / input) + "%" : null;
        var rows = [["总计", exact(total)]];
        if (hit) rows.push(["缓存命中", hit]);
        rows.push(["未缓存输入", exact(usage.uncachedInputTokens)], ["缓存读取", exact(usage.cacheReadTokens)],
          ["缓存写入", exact(usage.cacheWriteTokens)], ["输出", exact(usage.outputTokens)]);
        result.usage = { label: compact(total) + " tok" + (hit ? " · 缓存命中 " + hit : ""), title: "Token 用量", rows: rows };
      }
    }
    var projected = number(pressure.projectedTokens) ? pressure.projectedTokens : pressure.pressureTokens;
    var capacity = number(effective.contextWindow) && effective.contextWindow > 0 ? effective.contextWindow : stalePressure ? null : pressure.contextWindow;
    if ((number(projected) && number(capacity) && capacity > 0) || sessionAvailable) {
      var hasUsage = number(projected) && number(capacity) && capacity > 0;
      var percent = hasUsage ? Math.min(100, Math.round(projected * 100 / capacity)) : 0;
      var context = [];
      if (hasUsage) context.push(["预计使用", exact(projected)]);
      if (number(capacity) && capacity > 0) context.push(["上下文容量", exact(capacity)]);
      if (number(effective.autoCompactAt)) context.push(["自动压缩", exact(effective.autoCompactAt)]);
      var parts = [["systemTokens", "系统提示（估算）", "system"], ["toolsTokens", "工具（估算）", "tools"],
        ["messageTokens", "消息（估算）", "messages"]].filter(function (part) { return number(breakdown[part[0]]); });
      parts.forEach(function (part) { context.push([part[1], exact(breakdown[part[0]]), part[2]]); });
      var totalBreakdown = parts.reduce(function (sum, part) { return sum + breakdown[part[0]]; }, 0);
      var segments = parts.length === 3 && totalBreakdown ? parts.map(function (part) {
        return [part[2], percent * breakdown[part[0]] / totalBreakdown];
      }) : [["total", percent]];
      result.context = { label: hasUsage ? "上下文约 " + percent + "%" : "上下文", title: "上下文", rows: context, percent: percent, segments: segments };
    }
    return result;
  }

  function create() {
    var root = S.node("div", "dsh-bridge-conversation-metrics");
    root.setAttribute("role", "group");
    root.setAttribute("aria-label", "会话统计");
    var items = {}, listening = false, sessionID = null, sessionAvailable = false;
    var editor = null, editorPolicy = null, lastProjections = null, selectedModel = null, minimumRevision = 0;
    function position() {
      var area = root.parentNode;
      if (!area || typeof area.getBoundingClientRect !== "function") return;
      var bounds = area.getBoundingClientRect();
      Object.keys(items).forEach(function (key) {
        var details = items[key];
        if (!details.open) return;
        var anchor = details.getBoundingClientRect();
        var width = Math.min(key === "context" ? 264 : 300, Math.max(0, bounds.width - 24));
        var left = Math.min(Math.max(anchor.left, bounds.left + 12), bounds.right - 12 - width);
        details.__panel.style.width = width + "px";
        details.__panel.style.left = (left - anchor.left) + "px";
      });
    }
    function close(except) {
      Object.keys(items).forEach(function (key) { if (items[key] !== except) items[key].open = false; });
      if (editor && items.context !== except) editor.setActive(false);
      if (!except && listening) { document.removeEventListener("pointerdown", outside); listening = false; }
    }
    function outside(event) { if (!root.contains(event.target)) close(); }
    function openContextEditor(details) {
      if (!sessionAvailable || !global.CodexBridgeDesktopEmbeddedDSHContext) return;
      if (!editor) {
        editor = global.CodexBridgeDesktopEmbeddedDSHContext.create({ scope: "session", onPolicy: function (policy) {
          editorPolicy = policy; update(lastProjections);
        } });
        details.__panel.appendChild(editor.root);
      }
      editor.setSession(sessionID); editor.root.hidden = false; editor.setActive(true);
    }
    function item(key) {
      var details = S.node("details", "dsh-bridge-metric dsh-bridge-metric-" + key);
      var summary = S.node("summary", "dsh-bridge-metric-summary");
      var icon = S.node("span", "icon dsh-bridge-metric-icon"), label = S.node("span", "dsh-bridge-metric-label");
      icon.setAttribute("aria-hidden", "true");
      icon.innerHTML = '<svg viewBox="0 0 24 24">' + symbols[key] + '</svg>';
      var panel = S.node("section", "dsh-bridge-metric-panel");
      var title = S.node("h4", "dsh-bridge-metric-title"), list = S.node("dl", "dsh-bridge-metric-rows");
      var bar = key === "context" ? S.node("div", "dsh-bridge-metric-bar") : null;
      summary.appendChild(icon); summary.appendChild(label); panel.appendChild(title);
      if (bar) { bar.setAttribute("aria-hidden", "true"); panel.appendChild(bar); }
      panel.appendChild(list);
      details.appendChild(summary); details.appendChild(panel); root.appendChild(details);
      details.__summary = summary; details.__icon = icon; details.__label = label; details.__panel = panel;
      details.__title = title; details.__bar = bar; details.__list = list;
      details.addEventListener("toggle", function () {
        if (details.open) {
          close(details);
          if (key === "context") openContextEditor(details);
          position();
          if (!listening) { document.addEventListener("pointerdown", outside); listening = true; }
        } else {
          if (key === "context" && editor) editor.setActive(false);
          if (!Object.keys(items).some(function (name) { return items[name].open; })) close();
        }
      });
      details.addEventListener("keydown", function (event) {
        if (event.key === "Escape" && details.open) { event.preventDefault(); close(); summary.focus(); }
      });
      items[key] = details;
      return details;
    }
    function setSession(id, enabled) {
      var available = enabled !== false && typeof id === "string" && !!id;
      if (sessionID === id && sessionAvailable === available) return;
      sessionID = id || null; sessionAvailable = available; editorPolicy = null; selectedModel = null; minimumRevision = 0;
      if (editor) {
        editor.setActive(false); editor.setSession(available ? sessionID : null); editor.root.hidden = !available;
      }
    }
    function receive(item) {
      if (!item) return;
      if (item.type === "model/selection" && item.sessionID === sessionID) {
        var selection = item.payload || {};
        if (typeof selection.provider === "string" && typeof selection.model === "string") {
          selectedModel = { provider: selection.provider, model: selection.model };
          editorPolicy = null;
        }
        if (editor) editor.receive({ type: "context.changed", sessionID: sessionID });
        update(lastProjections);
      } else if (item.type === "context.changed" && (!item.sessionID || item.sessionID === sessionID)) {
        var revision = item.payload && item.payload.revision;
        if (number(revision)) minimumRevision = Math.max(minimumRevision, revision);
        if (editor) editor.receive(item);
        update(lastProjections);
      }
    }
    function update(projections) {
      lastProjections = projections;
      var next = values(projections, editorPolicy, sessionAvailable, selectedModel, minimumRevision), visible = false;
      ["activity", "usage", "context"].forEach(function (key) {
        var data = next[key], details = items[key] || item(key);
        details.hidden = !data;
        if (!data) { details.open = false; return; }
        visible = true;
        if (details.__label.textContent !== data.label) details.__label.textContent = data.label;
        if (key === "context" && details.__percent !== data.percent) {
          details.__icon.innerHTML = '<svg viewBox="0 0 24 24">' + symbols.context
            + '<circle cx="12" cy="12" r="8" pathLength="100" stroke-dasharray="' + data.percent
            + ' 100" transform="rotate(-90 12 12)"/></svg>';
          details.__percent = data.percent;
        }
        if (key === "context" && details.__segments !== JSON.stringify(data.segments)) {
          S.clear(details.__bar);
          data.segments.forEach(function (segment) {
            if (!segment[1]) return;
            var span = S.node("span", "dsh-bridge-metric-segment dsh-bridge-metric-segment-" + segment[0]);
            span.style.width = segment[1] + "%";
            details.__bar.appendChild(span);
          });
          details.__segments = JSON.stringify(data.segments);
        }
        if (details.__title.textContent !== data.title) details.__title.textContent = data.title;
        var signature = JSON.stringify(data.rows);
        if (details.__rows !== signature) {
          S.clear(details.__list);
          data.rows.forEach(function (row) {
            var term = S.node("dt");
            if (row[2]) {
              var swatch = S.node("span", "dsh-bridge-metric-swatch dsh-bridge-metric-segment-" + row[2]);
              swatch.setAttribute("aria-hidden", "true");
              term.appendChild(swatch);
            }
            term.appendChild(S.node("span", null, row[0]));
            details.__list.appendChild(term); details.__list.appendChild(S.node("dd", null, row[1]));
          });
          details.__rows = signature;
        }
      });
      root.hidden = !visible;
      position();
      if (!Object.keys(items).some(function (key) { return items[key].open; })) close();
    }
    return { root: root, update: update, position: position, close: close, setSession: setSession,
      receive: receive, dispose: close };
  }
  global.CodexBridgeDesktopEmbeddedDSHMetrics = { create: create, values: values };
}(window));
