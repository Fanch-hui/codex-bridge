(function (global) {
  "use strict";
  var S = global.CodexBridgeDesktopPageSupport;
  var C = global.CodexBridgeDesktopWorkbenchConversation;

  function render(container, values, page, emit, options) {
    var owner = options && options.owner ? options.owner : container;
    var context = C.contextKey(page), block = owner.__windowsConversationBlock;
    if (!block || block.context !== context) {
      if (block) detachBlock(block);
      block = owner.__windowsConversationBlock = {
        context: context,
        heading: S.node("h4", "subsection-title", "对话"),
        error: null,
        list: S.node("div", "conversation-list"),
        actions: null,
        actionButton: null,
        actionEmit: emit,
        actionTaskID: null
      };
    }
    block.actionEmit = emit;
    updateError(block, page);
    updateList(block.list, S.safeArray(values), page);
    updateActions(block, page);
    attachBlock(container, block);
  }

  function attachBlock(container, block) {
    var nodes = [block.heading, block.error, block.list, block.actions].filter(Boolean);
    nodes.forEach(function (node) {
      if (node.parentNode !== container) container.appendChild(node);
    });
    var firstIndex = container.children.length - nodes.length;
    nodes.forEach(function (node, index) { placeAt(container, node, firstIndex + index); });
  }

  function detachBlock(block) {
    [block.heading, block.error, block.list, block.actions].forEach(function (node) {
      if (node && node.parentNode) node.parentNode.removeChild(node);
    });
  }

  function updateError(block, page) {
    var state = page.selectedTask && page.selectedTask.conversationState;
    if (!state || !state.errorMessage) {
      if (block.error) block.error.remove();
      block.error = null;
      return;
    }
    if (!block.error) block.error = C.createError(state.errorMessage);
    else block.error.__message.textContent = state.errorMessage;
  }

  function updateActions(block, page) {
    var state = page.selectedTask && page.selectedTask.conversationState;
    var canLoadEarlier = state && typeof state.canLoadEarlier === "boolean"
      ? state.canLoadEarlier
      : page.browser && page.browser.canLoadEarlierConversation;
    var loading = !!(state && state.isLoadingEarlier);
    var visible = !!(page.selectedTaskID && (canLoadEarlier || loading));
    if (!visible) {
      if (block.actions) block.actions.remove();
      block.actions = block.actionButton = null;
      block.actionTaskID = null;
      return;
    }
    if (!block.actions) {
      block.actions = S.node("div", "conversation-actions");
      block.actionButton = S.button("", null, {}, function () {}, "small", false);
      block.actionButton.addEventListener("click", function () {
        if (block.actionEmit) block.actionEmit("loadEarlierConversation", { taskID: block.actionTaskID });
      });
      block.actions.appendChild(block.actionButton);
    }
    block.actionTaskID = page.selectedTaskID;
    block.actionButton.textContent = loading ? "正在加载更早消息…" : "加载更早的消息";
    block.actionButton.disabled = loading;
    if (loading) block.actionButton.setAttribute("aria-busy", "true");
    else if (block.actionButton.removeAttribute) block.actionButton.removeAttribute("aria-busy");
  }

  function updateList(list, values, page) {
    var state = page.selectedTask && page.selectedTask.conversationState;
    var nodes = list.__entryNodes || (list.__entryNodes = new Map());
    var entries = [], active = new Set();
    values.forEach(function (entry, index) {
      var key = entryKey(entry, index), type = entryType(entry), item = nodes.get(key);
      if (item && item.__entryType !== type) {
        item.remove(); item = null;
      }
      if (!item) {
        item = type === "process"
          ? global.CodexBridgeDesktopWorkbenchProcess.create(entry, C.contextKey(page))
          : type === "disclosure"
          ? C.createDisclosure(entry, C.contextKey(page))
          : C.createMessage(entry);
        item.__entryType = type;
        item.__entry = entry;
        nodes.set(key, item);
      }
      if (!sameEntry(item.__entry, entry)) {
        if (type === "process") global.CodexBridgeDesktopWorkbenchProcess.update(item, entry);
        else if (type === "disclosure") C.updateDisclosure(item, entry, C.contextKey(page));
        else C.updateMessage(item, entry);
        item.__entry = entry;
      }
      active.add(key); entries.push(item);
    });
    nodes.forEach(function (item, key) {
      if (!active.has(key)) { item.remove(); nodes.delete(key); }
    });

    var leading = [];
    if (state && state.isLoading && !state.showsActivity) {
      leading.push(list.__loadingNode || (list.__loadingNode = C.createLoading("正在同步对话内容…")));
    }
    if (state && state.isLoadingEarlier) {
      leading.push(list.__earlierNode || (list.__earlierNode = C.createEarlierLoading()));
    }
    if (!values.length && state && !state.isLoading && !state.showsActivity && !state.errorMessage) {
      leading.push(list.__emptyNode || (list.__emptyNode = S.node("p", "muted", "暂无对话记录。")));
    }
    var activity = null;
    if (state && state.showsActivity) {
      activity = list.__activityNode;
      if (!activity) activity = list.__activityNode = C.createActivity(state);
      else C.updateActivity(activity, state);
    }
    var known = new Set(leading.concat(entries, activity ? [activity] : []));
    Array.prototype.slice.call(list.children).forEach(function (child) {
      if (!known.has(child)) child.remove();
    });
    leading.forEach(function (node, index) { placeAt(list, node, index); });
    entries.forEach(function (node, index) { placeAt(list, node, leading.length + index); });
    if (activity) placeAt(list, activity, leading.length + entries.length);
  }

  function placeAt(parent, node, index) {
    var current = parent.children[index];
    if (current === node) return;
    if (current) parent.insertBefore(node, current);
    else parent.appendChild(node);
  }

  function entryKey(entry, index) {
    return entry && entry.id !== undefined && entry.id !== null ? String(entry.id) : "missing-" + index;
  }

  function entryType(entry) {
    if (entry.kind === "process") return "process";
    return entry.kind === "reasoning" || entry.kind === "tool_call" ? "disclosure" : "message";
  }

  function sameEntry(previous, entry) {
    if (entry.kind === "process") return !!previous && !!previous.processEntries
      && previous.processEntries.length === entry.processEntries.length
      && entry.processEntries.every(function (value, index) { return sameEntry(previous.processEntries[index], value); });
    return !!previous && previous.role === entry.role && previous.text === entry.text
      && previous.kind === entry.kind && previous.toolName === entry.toolName
      && previous.toolStatus === entry.toolStatus && previous.toolArguments === entry.toolArguments
      && previous.displayTitle === entry.displayTitle && previous.displayStatus === entry.displayStatus
      && previous.symbol === entry.symbol && previous.isFinal === entry.isFinal
      && previous.status === entry.status && previous.markdownHTML === entry.markdownHTML;
  }

  global.CodexBridgeDesktopWorkbenchConversationIncremental = {
    render: render
  };
}(window));
