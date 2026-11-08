(function (global) {
  "use strict";

  function node(tag, className, value) {
    var element = document.createElement(tag);
    if (className) element.className = className;
    if (value !== undefined && value !== null) element.textContent = String(value);
    return element;
  }
  function button(label, className, callback) {
    var element = node("button", className || "button small", label);
    element.type = "button";
    element.addEventListener("click", callback);
    return element;
  }
  function text(element, value) {
    value = value == null ? "" : String(value);
    if (element.textContent !== value) element.textContent = value;
  }
  function time(value) {
    if (!value) return "";
    var date = new Date(value);
    return isNaN(date.getTime()) ? String(value) : date.toLocaleString();
  }
  function field(label, control) {
    var wrapper = node("label", "field message-center-field");
    wrapper.appendChild(node("span", null, label));
    wrapper.appendChild(control);
    return wrapper;
  }
  function createAttachments(handlers, scope) {
    var root = node("div", "message-center-attachment-area");
    var list = node("div", "message-center-attachments");
    var add = button("添加图片", "button small", function () { handlers.addAttachments(scope()); });
    root.appendChild(list);
    root.appendChild(add);
    return { root: root, list: list, add: add };
  }
  function updateAttachments(view, attachments, scope, handlers, busy) {
    var filtered = (Array.isArray(attachments) ? attachments : []).filter(function (item) {
      return (item.feedbackID || "") === (scope || "");
    });
    var signature = JSON.stringify([scope, filtered]);
    if (view.signature !== signature) {
      view.signature = signature;
      while (view.list.firstChild) view.list.removeChild(view.list.firstChild);
      filtered.forEach(function (item) {
        var row = node("div", "message-center-attachment");
        var name = node("span", "message-center-attachment-name", item.name || "图片");
        name.title = item.name || "图片";
        row.appendChild(name);
        var preview = button("预览", "button link-button small", function () {
          handlers.previewAttachment(scope, item.id);
        });
        preview.setAttribute("aria-label", "预览 " + (item.name || "图片"));
        row.appendChild(preview);
        var remove = button("移除", "button link-button small", function () {
          handlers.removeAttachment(scope, item.id);
        });
        remove.disabled = busy;
        remove.setAttribute("aria-label", "移除 " + (item.name || "图片"));
        row.appendChild(remove);
        view.list.appendChild(row);
      });
    }
    Array.prototype.forEach.call(view.list.children, function (row) { row.children[2].disabled = busy; });
    view.add.disabled = busy || filtered.length >= 3;
  }
  function createForm(handlers, scope, isNew) {
    var root = node("div", "message-center-form");
    var category = null;
    if (isNew) {
      category = node("select");
      [["bug", "问题反馈"], ["suggestion", "功能建议"], ["other", "其他"]].forEach(function (choice) {
        var option = node("option", null, choice[1]); option.value = choice[0]; category.appendChild(option);
      });
      category.value = "bug";
      root.appendChild(field("反馈类型", category));
      category.addEventListener("change", function () { handlers.draft(scope(), input.value, category.value); });
    }
    var input = node("textarea", "message-center-input");
    input.placeholder = isNew ? "描述遇到的问题或你的建议…" : "补充说明…";
    input.rows = isNew ? 7 : 3;
    input.maxLength = 16000;
    input.addEventListener("input", function () { handlers.draft(scope(), input.value, category ? category.value : null); });
    root.appendChild(field(isNew ? "反馈内容" : "回复", input));
    var attachments = createAttachments(handlers, scope);
    root.appendChild(attachments.root);
    var metadata = isNew ? node("p", "message-center-meta") : null;
    if (metadata) root.appendChild(metadata);
    var footer = node("div", "message-center-form-footer");
    var error = node("p", "message-center-form-error"); error.setAttribute("role", "status");
    var submit = button(isNew ? "发送反馈" : "发送回复", "button primary small", function () {
      handlers.submit(scope(), input.value, category ? category.value : null);
    });
    footer.appendChild(error); footer.appendChild(submit); root.appendChild(footer);
    return { root: root, input: input, category: category, attachments: attachments, metadata: metadata, error: error, submit: submit };
  }
  function makeRow(handlers, kind, item) {
    var row = button("", "message-center-row", function () { handlers.select(kind, item.id); });
    row.appendChild(node("span", "message-center-row-title"));
    row.appendChild(node("span", "message-center-row-meta"));
    row.appendChild(node("span", "message-center-row-unread"));
    return row;
  }
  function syncRows(container, nodes, kind, items, selected, handlers) {
    nodes.forEach(function (row, key) {
      if (key.indexOf(kind + ":") !== 0 && row.parentNode === container) row.remove();
    });
    var existing = new Set();
    items.forEach(function (item, index) {
      if (!item || !item.id) return;
      var id = String(item.id), key = kind + ":" + id, row = nodes.get(key);
      existing.add(key);
      if (!row) { row = makeRow(handlers, kind, item); nodes.set(key, row); }
      var message = item.messages && item.messages[0];
      var title = kind === "notice" ? item.title : message && message.body;
      text(row.children[0], String(title || "反馈").split("\n")[0]);
      text(row.children[1], time(item.publishedAt || item.updatedAt || item.createdAt));
      var unread = kind === "notice" ? item.isRead === false : Number(item.unreadCount || 0) > 0;
      row.children[2].hidden = !unread;
      row.classList.toggle("is-selected", selected === id);
      row.setAttribute("aria-current", selected === id ? "true" : "false");
      if (container.children[index] !== row) container.insertBefore(row, container.children[index] || null);
    });
    nodes.forEach(function (row, key) {
      if (key.indexOf(kind + ":") === 0 && !existing.has(key)) { row.remove(); nodes.delete(key); }
    });
  }
  function safeMarkdown(target, value) {
    var next = String(value || "");
    if (target.__messageText === next) return;
    target.__messageText = next;
    var renderer = global.CodexBridgeDesktopEmbeddedDSHMarkdown;
    if (renderer && renderer.render) target.innerHTML = renderer.render(next);
    else target.textContent = next;
  }
  function syncMessages(container, nodes, feedback, handlers) {
    var previousScroll = container.scrollTop, keep = new Set();
    (feedback.messages || []).forEach(function (message, index) {
      if (!message || !message.id) return;
      var id = String(message.id), item = nodes.get(id);
      keep.add(id);
      if (!item) {
        item = node("article", "message-center-conversation-item");
        item.appendChild(node("div", "message-center-conversation-meta"));
        item.appendChild(node("div", "message-center-conversation-text"));
        item.appendChild(node("div", "message-center-conversation-attachments"));
        nodes.set(id, item);
      }
      text(item.children[0], (message.author === "admin" ? "开发者" : "我") + " · " + time(message.createdAt));
      text(item.children[1], message.body || "");
      var attachmentArea = item.children[2], attachmentSignature = JSON.stringify(message.attachments || []);
      if (attachmentArea.__signature !== attachmentSignature) {
        attachmentArea.__signature = attachmentSignature;
        while (attachmentArea.firstChild) attachmentArea.removeChild(attachmentArea.firstChild);
        (message.attachments || []).forEach(function (attachment) {
          var link = button(attachment.name || "查看图片", "button link-button small", function () {
            handlers.openAttachment(feedback.id, attachment.id);
          });
          attachmentArea.appendChild(link);
        });
      }
      if (container.children[index] !== item) container.insertBefore(item, container.children[index] || null);
    });
    nodes.forEach(function (item, id) { if (!keep.has(id)) { item.remove(); nodes.delete(id); } });
    container.scrollTop = previousScroll;
  }
  function noticeAction(value) {
    if (!value || !value.label || typeof value.label !== "string") return null;
    if (value.kind === "update") return { kind: "update", label: value.label };
    if (value.kind !== "url" || typeof value.url !== "string") return null;
    try {
      var url = new URL(value.url);
      if (url.protocol !== "https:" || !url.hostname || url.username || url.password || url.port) return null;
      return { kind: "url", label: value.label, url: url.href };
    } catch (_) { return null; }
  }
  function makeDetail(handlers) {
    var root = node("section", "message-center-detail");
    var placeholder = node("p", "message-center-empty", "选择一条消息查看详情");
    var notice = node("div", "message-center-notice");
    var title = node("h3", "message-center-title"), meta = node("p", "message-center-meta");
    var body = node("div", "markdown-body message-center-notice-body");
    body.addEventListener("click", function (event) {
      var link = event.target && event.target.closest && event.target.closest("a");
      if (!link || !body.contains(link)) return;
      event.preventDefault();
      var value = link.getAttribute("href");
      if (value) handlers.openExternalURL(value);
    });
    var action = button("", "button small message-center-notice-action", function () {
      if (notice.__action) handlers.noticeAction(notice.__action);
    });
    notice.appendChild(title); notice.appendChild(meta); notice.appendChild(body); notice.appendChild(action);
    var feedback = node("div", "message-center-feedback-detail");
    var status = node("p", "message-center-meta");
    var messages = node("div", "message-center-conversation");
    var currentID = "";
    var reply = createForm(handlers, function () { return currentID; }, false);
    feedback.appendChild(status); feedback.appendChild(messages); feedback.appendChild(reply.root);
    var compose = createForm(handlers, function () { return ""; }, true);
    root.appendChild(placeholder); root.appendChild(notice); root.appendChild(feedback); root.appendChild(compose.root);
    return { root: root, placeholder: placeholder, notice: notice, title: title, meta: meta, body: body,
      feedback: feedback, status: status, messages: messages, messageNodes: new Map(), reply: reply, compose: compose, action: action,
      feedbackID: function (value) { if (value !== undefined) currentID = value; return currentID; } };
  }
  function create(handlers) {
    var dialog = node("dialog", "component-dialog message-center-dialog");
    dialog.setAttribute("aria-labelledby", "message-center-title");
    var header = node("div", "dialog-header message-center-header");
    var title = node("h2", null, "消息信箱"); title.id = "message-center-title";
    var close = button("关闭", "button small", function () { dialog.close(); });
    header.appendChild(title); header.appendChild(close); dialog.appendChild(header);
    var toolbar = node("div", "message-center-toolbar");
    var tabs = node("div", "message-center-tabs"); tabs.setAttribute("role", "tablist");
    var notices = button("通知", "message-center-tab", function () { handlers.tab("notice"); });
    var feedbacks = button("我的反馈", "message-center-tab", function () { handlers.tab("feedback"); });
    notices.id = "message-center-notices-tab"; feedbacks.id = "message-center-feedback-tab";
    notices.setAttribute("role", "tab"); feedbacks.setAttribute("role", "tab");
    notices.setAttribute("aria-controls", "message-center-list"); feedbacks.setAttribute("aria-controls", "message-center-list");
    tabs.setAttribute("aria-label", "消息分类");
    tabs.addEventListener("keydown", function (event) {
      if (["ArrowLeft", "ArrowRight", "Home", "End"].indexOf(event.key) < 0) return;
      event.preventDefault();
      var showNotice = event.key === "Home" || (event.key !== "End" && event.target === feedbacks);
      handlers.tab(showNotice ? "notice" : "feedback");
      (showNotice ? notices : feedbacks).focus();
    });
    tabs.appendChild(notices); tabs.appendChild(feedbacks); toolbar.appendChild(tabs);
    var markAll = button("全部已读", "button link-button small", handlers.markAll);
    var compose = button("写反馈", "button small", handlers.compose);
    var retry = button("重试", "button small", handlers.refresh);
    toolbar.appendChild(markAll); toolbar.appendChild(compose); toolbar.appendChild(retry); dialog.appendChild(toolbar);
    var status = node("p", "message-center-status"); status.setAttribute("role", "status");
    dialog.appendChild(status);
    var layout = node("div", "message-center-layout");
    var list = node("div", "message-center-list"); list.id = "message-center-list";
    list.setAttribute("role", "tabpanel"); list.setAttribute("aria-label", "消息列表");
    var empty = node("p", "message-center-empty");
    var rows = node("div", "message-center-rows"); list.appendChild(empty); list.appendChild(rows);
    var detail = makeDetail(handlers); layout.appendChild(list); layout.appendChild(detail.root); dialog.appendChild(layout);
    dialog.addEventListener("click", function (event) { if (event.target === dialog) dialog.close(); });
    dialog.addEventListener("close", handlers.close);
    document.body.appendChild(dialog);
    return { dialog: dialog, notices: notices, feedbacks: feedbacks, compose: compose, markAll: markAll, retry: retry, list: list,
      status: status, empty: empty, rows: rows, rowNodes: new Map(), detail: detail };
  }
  function setForm(view, value, category, attachments, scope, state, busy, handlers, errorVisible) {
    if (view.metadata) {
      var platforms = { macos: "macOS", windows: "Windows", linux: "Linux" };
      text(view.metadata, "随反馈发送：版本 " + (state.appVersion || "—") + " · 系统 " + (platforms[state.platform] || state.platform || "—"));
    }
    if (view.input.value !== value) view.input.value = value;
    if (view.category && view.category.value !== category) view.category.value = category;
    var trimmed = value.trim();
    var tooLong = new TextEncoder().encode(trimmed).length > 16000;
    view.submit.disabled = busy || !trimmed || tooLong;
    view.input.setAttribute("aria-invalid", String(tooLong));
    view.submit.setAttribute("aria-busy", String(busy));
    text(view.error, tooLong ? "内容过长，请缩短后发送。" : errorVisible && !busy ? state.submissionError || "" : "");
    view.error.hidden = !view.error.textContent;
    updateAttachments(view.attachments, attachments, scope, handlers, busy);
  }
  function update(view, state, context, handlers) {
    var noticeTab = context.tab === "notice", detail = view.detail, items = noticeTab ? state.notices : state.feedbacks;
    items = Array.isArray(items) ? items : [];
    view.notices.setAttribute("aria-selected", String(noticeTab));
    view.feedbacks.setAttribute("aria-selected", String(!noticeTab));
    view.notices.tabIndex = noticeTab ? 0 : -1; view.feedbacks.tabIndex = noticeTab ? -1 : 0;
    view.list.setAttribute("aria-labelledby", noticeTab ? "message-center-notices-tab" : "message-center-feedback-tab");
    view.notices.classList.toggle("is-selected", noticeTab); view.feedbacks.classList.toggle("is-selected", !noticeTab);
    view.markAll.hidden = !noticeTab;
    view.retry.hidden = !state.error; view.retry.disabled = !!state.isRefreshing;
    text(view.status, state.error || (state.isRefreshing ? "正在刷新…" : "")); view.status.hidden = !view.status.textContent;
    text(view.empty, noticeTab ? "暂无通知" : "暂无反馈"); view.empty.hidden = items.length > 0;
    var selected = context.selected[context.tab] || "";
    syncRows(view.rows, view.rowNodes, context.tab, items, selected, handlers);
    view.rowNodes.forEach(function (row, key) { row.hidden = key.indexOf(context.tab + ":") !== 0; });
    var item = items.find(function (row) { return String(row.id) === selected; });
    detail.placeholder.hidden = !!item || context.composing;
    detail.notice.hidden = !item || !noticeTab || context.composing;
    detail.feedback.hidden = !item || noticeTab || context.composing;
    detail.compose.root.hidden = !context.composing;
    if (item && noticeTab && !context.composing) {
      var scroll = detail.notice.scrollTop;
      text(detail.title, item.title); text(detail.meta, (item.priority === "important" ? "重要 · " : "") + time(item.publishedAt));
      safeMarkdown(detail.body, item.body);
      detail.notice.__action = noticeAction(item.action);
      detail.action.hidden = !detail.notice.__action;
      text(detail.action, detail.notice.__action && detail.notice.__action.label);
      detail.notice.scrollTop = scroll;
    }
    if (item && !noticeTab && !context.composing) {
      if (detail.feedbackID() !== String(item.id)) {
        detail.feedbackID(String(item.id)); detail.messageNodes.clear();
        while (detail.messages.firstChild) detail.messages.removeChild(detail.messages.firstChild);
        detail.messages.scrollTop = 0;
      }
      var labels = { received: "已收到", processing: "处理中", resolved: "已解决" };
      text(detail.status, labels[item.status] || "处理中");
      syncMessages(detail.messages, detail.messageNodes, item, handlers);
      setForm(detail.reply, context.replyDrafts[String(item.id)] || "", null, state.draftAttachments,
        String(item.id), state, !!state.isSubmitting, handlers, context.errorScope === "reply:" + String(item.id));
    }
    if (context.composing) {
      setForm(detail.compose, context.newDraft.input || "", context.newDraft.category || "bug", state.draftAttachments,
        "", state, !!state.isSubmitting, handlers, context.errorScope === "feedback:");
    }
  }
  global.CodexBridgeMessageCenterView = { create: create, update: update };
}(window));
