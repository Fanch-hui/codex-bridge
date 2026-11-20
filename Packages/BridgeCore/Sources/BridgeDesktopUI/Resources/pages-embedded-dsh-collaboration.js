(function (global) {
  "use strict";
  var S = global.CodexBridgeDesktopPageSupport;
  var activeStatuses = ["running", "starting", "created", "queued", "waiting-for-workspace", "stopping"];
  var attentionWorkspace = ["conflict", "failed", "recovery_required", "validation_required", "retained"];
  var providerNames = { codex: "Codex", "claude-code": "Claude Code", opencode: "OpenCode", pi: "Pi",
    antigravity: "Antigravity", qoder: "Qoder", "deepseek-harness": "DeepSeek Harness",
    "deepseek-harness-desktop": "DeepSeek Harness" };
  var workspaceStatuses = { pending: "待合并", merged: "已合并", conflict: "合并冲突", retained: "变更已保留",
    failed: "合并失败", validation_required: "待验证", validating: "验证中", recovery_required: "待恢复", merging: "合并中" };

  function childID(item) { return item.childId || item.id || item.sessionId || ""; }
  function needsAttention(item) {
    return !!item.waitingForApproval || item.status === "awaiting_local_approval" || item.status === "failed"
      || item.status === "unknown" || attentionWorkspace.includes(item.workspaceStatus);
  }
  function isActive(item) {
    return activeStatuses.includes(item.status) || item.running === true || (item.waitingFor || []).length > 0
      || Number(item.queuedCount) > 0;
  }
  function priority(item) { return needsAttention(item) ? 0 : isActive(item) ? 1 : 2; }
  function sort(items) {
    return items.map(function (item, index) { return { item: item, index: index }; })
      .sort(function (a, b) { return priority(a.item) - priority(b.item) || a.index - b.index; })
      .map(function (entry) { return entry.item; });
  }
  function counts(items) {
    return items.reduce(function (total, item) {
      if (needsAttention(item)) total.attention++;
      else if (["running", "starting"].includes(item.status) || item.running === true && !item.status) total.running++;
      else if (isActive(item)) total.waiting++;
      return total;
    }, { running: 0, waiting: 0, attention: 0 });
  }
  function assign(node, text) { if (node.textContent !== text) node.textContent = text; }
  function addCount(root, symbol, label) {
    var part = S.node("span", "dsh-collaboration-count");
    var icon = S.node("span", "dsh-collaboration-count-icon", symbol), number = S.node("span");
    icon.setAttribute("aria-hidden", "true"); part.setAttribute("role", "img"); part.appendChild(icon); part.appendChild(number); root.appendChild(part);
    return { root: part, number: number, label: label };
  }
  function modeText(item) {
    var mode = item.workspaceMode === "isolated" ? "隔离副本" : item.workspaceMode === "shared" ? "共享目录"
      : item.workspaceMode === "read-only" ? "只读" : item.mode === "native" ? "共享目录" : "";
    if (item.workspaceReason && item.workspaceMode === "shared") mode += (mode ? " · " : "") + item.workspaceReason;
    return mode;
  }
  function modelText(item, agentName) {
    var id = item.providerID || item.installationID || "";
    var name = item.installationID && agentName ? agentName(item.installationID) : "";
    var agent = providerNames[id] || name || item.installationID || (item.mode === "native" ? "工作台" : id);
    return [agent, item.model || ""].filter(Boolean).join(" · ");
  }
  function changesText(item) {
    var count = Array.isArray(item.changedFiles) ? item.changedFiles.length + (Number(item.changedFilesOmitted) || 0) : null;
    var status = workspaceStatuses[item.workspaceStatus] || "";
    return [count === null ? "" : count + " 个文件", status].filter(Boolean).join(" · ");
  }
  function labelFor(item) { return item && (item.label || item.name || item.title || item.provider || item.installationID || childID(item)) || "Agent"; }

  function create(options) {
    var summary = S.node("div", "dsh-collaboration-summary");
    var running = addCount(summary, "●", "运行中"), waiting = addCount(summary, "◷", "等待中"), attention = addCount(summary, "!", "待处理");
    summary.setAttribute("aria-label", "协作状态");
    function updateSummary(items) {
      var value = counts(items);
      [[running, value.running], [waiting, value.waiting], [attention, value.attention]].forEach(function (entry) {
        assign(entry[0].number, String(entry[1]));
        entry[0].root.setAttribute("aria-label", entry[1] + " 个" + entry[0].label);
        entry[0].root.title = entry[1] + " 个" + entry[0].label;
      });
    }
    function makeRow(row) {
      var wrapper = S.node("div", "dsh-collaboration-row"), metadata = S.node("div", "dsh-collaboration-meta");
      var model = S.node("span", "dsh-collaboration-model"), workspace = S.node("span", "dsh-collaboration-workspace");
      var changes = S.node("span", "dsh-collaboration-changes"), dependencies = S.node("div", "dsh-collaboration-dependencies");
      var waitingLabel = S.node("span", null, "等待"), links = new Map();
      dependencies.appendChild(waitingLabel);
      var locate = S.button("在对话中定位", null, {}, null, "dsh-collaboration-locate");
      locate.addEventListener("click", function () { options.locateConversation(row.id); });
      metadata.appendChild(model); metadata.appendChild(workspace); metadata.appendChild(changes);
      wrapper.appendChild(row.item); wrapper.appendChild(metadata); wrapper.appendChild(dependencies); wrapper.appendChild(locate);
      row.collaborationItem = wrapper;
      row.collaboration = { model: model, workspace: workspace, changes: changes, dependencies: dependencies,
        links: links, locate: locate };
      return row.collaboration;
    }
    function setPart(node, value) { assign(node, value); node.hidden = !value; }
    function decorate(row, item, items) {
      var view = row.collaboration || makeRow(row);
      setPart(view.model, modelText(item, options.agentName));
      setPart(view.workspace, modeText(item));
      setPart(view.changes, changesText(item));
      var available = new Map(items.map(function (value) { return [childID(value), value]; }));
      var waitingFor = Array.isArray(item.waitingFor) ? item.waitingFor : [];
      var ids = waitingFor.map(function (value) { return value.childID; }).filter(Boolean);
      var keep = new Set(ids);
      view.links.forEach(function (link, id) {
        if (!keep.has(id)) { link.remove(); view.links.delete(id); }
      });
      ids.forEach(function (id, index) {
        var link = view.links.get(id);
        if (!link) {
          link = S.button("", null, {}, null, "dsh-collaboration-dependency");
          link.addEventListener("click", function () { options.openChild(id); });
          view.links.set(id, link);
        }
        assign(link, available.has(id) ? labelFor(available.get(id)) : id);
        link.setAttribute("aria-label", "查看等待的 " + (available.has(id) ? labelFor(available.get(id)) : id));
        var reference = view.dependencies.children[index + 1] || null;
        if (reference !== link) view.dependencies.insertBefore(link, reference);
      });
      view.dependencies.hidden = !ids.length;
      return row.collaborationItem;
    }
    function focus(row) {
      if (!row || !row.collaborationItem) return;
      if (row.collaborationItem.scrollIntoView) row.collaborationItem.scrollIntoView({ block: "nearest" });
      if (row.item.focus) row.item.focus({ preventScroll: true });
    }
    function reset() {
      updateSummary([]);
    }
    reset();
    return { summary: summary, sort: sort, updateSummary: updateSummary, decorate: decorate, focus: focus, reset: reset };
  }
  global.CodexBridgeDesktopEmbeddedDSHCollaboration = { create: create, sort: sort, counts: counts, needsAttention: needsAttention };
  if (typeof module !== "undefined" && module.exports) module.exports = global.CodexBridgeDesktopEmbeddedDSHCollaboration;
}(typeof window === "undefined" ? globalThis : window));
