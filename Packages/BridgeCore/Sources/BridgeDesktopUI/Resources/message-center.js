(function (global) {
  "use strict";
  var storageKey = "codexBridge.messageCenter.drafts.v1";
  var saved = {}, storageError = "";
  try { saved = JSON.parse(global.localStorage.getItem(storageKey) || "{}") || {}; }
  catch (_) { storageError = "草稿无法读取，本次输入仍可继续。"; }
  var context = {
    tab: "notice", selected: { notice: "", feedback: "" }, composing: false,
    newDraft: saved.newDraft || { category: "bug", input: "" }, replyDrafts: saved.replyDrafts || {},
    pending: saved.pending || null, pendingKind: "", errorScope: ""
  };
  if (context.pending) {
    context.pending.active = false; context.pending.recovered = true;
    context.errorScope = context.pending.kind === "feedback" ? "feedback:" : "reply:" + context.pending.scope;
  }
  var current = null, emit = null, view = null, sentReads = new Set(), visibilityBound = false;

  function persist() {
    try {
      global.localStorage.setItem(storageKey, JSON.stringify({
        newDraft: context.newDraft, replyDrafts: context.replyDrafts, pending: context.pending
      }));
      storageError = "";
    } catch (_) { storageError = "草稿无法保存，关闭窗口后可能丢失。"; }
  }
  function send(command, payload) { if (emit) emit(command, payload || {}); }
  function measure() {
    var pages = global.CodexBridgeDesktopPages;
    if (pages && pages.measureBrowserViewport && emit) pages.measureBrowserViewport(emit);
  }
  function selected() {
    var entries = context.tab === "notice" ? current.notices : current.feedbacks;
    var id = context.selected[context.tab];
    return (Array.isArray(entries) ? entries : []).find(function (item) { return item && String(item.id) === id; });
  }
  function markSelectedRead() {
    if (!current || !view || !view.dialog.open || context.composing) return;
    var item = selected();
    if (!item) return;
    var signature;
    if (context.tab === "notice") {
      if (item.isRead !== false) return;
      signature = "notice:" + item.id + ":" + item.revision;
    } else {
      if (!(Number(item.unreadCount || 0) > 0)) return;
      var replies = (item.messages || []).filter(function (message) { return message.author === "admin"; });
      signature = "feedback:" + item.id + ":" + (replies.length ? replies[replies.length - 1].id : item.updatedAt);
    }
    if (sentReads.has(signature)) return;
    sentReads.add(signature);
    send("messageCenterMarkRead", { kind: context.tab, value: item.id });
  }
  function setTab(value) {
    context.tab = value; context.composing = false;
    if (view) view.detail.notice.scrollTop = 0;
    markSelectedRead(); draw();
  }
  function select(kind, id) {
    context.tab = kind; context.composing = false; context.selected[kind] = String(id);
    sentReads.clear();
    if (view) view.detail.notice.scrollTop = 0;
    markSelectedRead(); draw();
  }
  function saveDraft(scope, value, category) {
    if (scope) context.replyDrafts[String(scope)] = value;
    else context.newDraft = { input: value, category: category || "bug" };
    persist(); draw();
  }
  function submit(scope, value, category) {
    if (!value.trim() || (current && current.isSubmitting) || (context.pending && context.pending.active)) return;
    var kind = scope ? "reply" : "feedback", receipt = current && current.submissionReceipt;
    context.pending = { kind: kind, scope: scope || "", input: value, category: category || "bug",
      baseline: receipt && receipt.requestID || "", baselineAttemptID: current && current.submissionAttemptID || "",
      active: true, seenBusy: false };
    context.pendingKind = kind; context.errorScope = scope ? "reply:" + scope : "feedback:"; persist(); draw();
    if (scope) send("messageCenterReply", { feedbackID: scope, input: value });
    else send("messageCenterSubmitFeedback", { kind: category || "bug", input: value });
  }
  function scopedPayload(scope, id) {
    var payload = {};
    if (scope) payload.feedbackID = scope;
    if (id) payload.value = id;
    return payload;
  }
  var handlers = {
    tab: setTab, select: select,
    markAll: function () { send("messageCenterMarkAllRead"); },
    refresh: function () { send("messageCenterRefresh"); },
    compose: function () { context.tab = "feedback"; context.composing = true; draw(); },
    draft: saveDraft, submit: submit,
    addAttachments: function (scope) {
      context.errorScope = scope ? "reply:" + scope : "feedback:";
      send("messageCenterSelectAttachments", scopedPayload(scope));
    },
    removeAttachment: function (scope, id) {
      context.errorScope = scope ? "reply:" + scope : "feedback:";
      send("messageCenterRemoveAttachment", scopedPayload(scope, id));
    },
    previewAttachment: function (scope, id) {
      context.errorScope = scope ? "reply:" + scope : "feedback:";
      send("messageCenterPreviewAttachment", scopedPayload(scope, id));
    },
    openAttachment: function (scope, id) { send("messageCenterOpenAttachment", scopedPayload(scope, id)); },
    openExternalURL: function (value) { send("openExternalURL", { value: value }); },
    noticeAction: function (action) {
      if (action.kind === "url") { send("openExternalURL", { value: action.url }); return; }
      if (action.kind === "update") {
        view.dialog.close();
        send("checkAppUpdate");
        if (global.CodexBridgeDesktopAppUpdate) global.CodexBridgeDesktopAppUpdate.openDialog();
      }
    },
    close: measure
  };
  function acceptReceipt(receipt) {
    var pending = context.pending;
    if (!pending || !receipt || !receipt.requestID || receipt.requestID === pending.baseline || receipt.kind !== pending.kind) return false;
    if (pending.kind === "reply" && receipt.id !== pending.scope) return false;
    if (pending.kind === "feedback") {
      if (context.newDraft.input === pending.input) context.newDraft.input = "";
      context.tab = "feedback"; context.composing = false; context.selected.feedback = String(receipt.id);
    } else if (context.replyDrafts[pending.scope] === pending.input) {
      delete context.replyDrafts[pending.scope];
    }
    context.pending = null; context.pendingKind = ""; context.errorScope = ""; persist();
    return true;
  }
  function reconcile(state) {
    if (acceptReceipt(state.submissionReceipt)) return;
    var pending = context.pending;
    if (!pending) return;
    context.pendingKind = pending.kind;
    if (state.isSubmitting) pending.seenBusy = true;
    else if (state.submissionError && (pending.seenBusy
      || (state.submissionAttemptID && state.submissionAttemptID !== pending.baselineAttemptID))) {
      pending.active = false; persist();
    }
  }
  function draw() {
    if (!view || !current) return;
    var presentation = Object.assign({}, current);
    presentation.isSubmitting = !!current.isSubmitting || !!(context.pending && context.pending.active);
    if (context.pending && context.pending.recovered && !presentation.submissionError) {
      presentation.submissionError = "提交尚未确认，请重试。";
    }
    if (!presentation.error && storageError) presentation.error = storageError;
    global.CodexBridgeMessageCenterView.update(view, presentation, context, handlers);
  }
  function open() {
    if (!current) return;
    if (!view) view = global.CodexBridgeMessageCenterView.create(handlers);
    sentReads.clear(); draw();
    if (view.dialog.showModal && !view.dialog.open) view.dialog.showModal();
    else view.dialog.setAttribute("open", "");
    markSelectedRead(); measure(); send("messageCenterRefresh");
  }
  function render(state, callback) {
    if (document.documentElement.dataset.surface === "preferences") return;
    emit = callback; current = state || null;
    if (document.documentElement.dataset.platform === "linux" && !visibilityBound) {
      visibilityBound = true;
      document.addEventListener("visibilitychange", function () {
        send("messageCenterSetVisible", { enabled: !document.hidden });
      });
      send("messageCenterSetVisible", { enabled: !document.hidden });
    }
    var entry = document.getElementById("message-center-button");
    var badge = document.getElementById("message-center-badge");
    if (!entry || !badge) return;
    if (!entry.__messageCenterBound) {
      entry.__messageCenterBound = true; entry.addEventListener("click", open);
    }
    entry.disabled = !current;
    var count = Math.max(0, Math.floor(Number(current && current.unreadCount) || 0));
    badge.hidden = count === 0; badge.textContent = count > 99 ? "99+" : count ? String(count) : "";
    var label = count ? "消息信箱，" + count + " 条未读" : "消息信箱";
    entry.setAttribute("aria-label", label); entry.title = label;
    if (!current) return;
    reconcile(current); markSelectedRead(); draw();
  }
  global.CodexBridgeMessageCenter = { render: render };
}(window));
