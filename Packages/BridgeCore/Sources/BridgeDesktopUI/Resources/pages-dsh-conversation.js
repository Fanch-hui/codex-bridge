(function (global) {
  "use strict";
  var S = global.CodexBridgeDesktopPageSupport;
  var P = global.CodexBridgeDesktopWorkbenchSubmissions;

  function surface(content) {
    var view = content.__dshConversationSurface;
    if (!view) {
      view = content.__dshConversationSurface = {
        root: S.node("section", "dsh-chat-content"),
        empty: S.node("div", "dsh-chat-empty"),
        title: S.node("h3", "dsh-chat-empty-title"),
        conversation: S.node("div", "dsh-chat-conversation"),
        failure: S.node("details", "dsh-chat-failure")
      };
      view.empty.appendChild(view.title);
      view.failure.appendChild(S.node("summary", "disclosure-summary"));
      view.failure.__body = S.node("div", "dsh-chat-failure-body");
      view.failure.appendChild(view.failure.__body);
      [view.empty, view.conversation, view.failure].forEach(function (node) { view.root.appendChild(node); });
    }
    Array.from(content.children).forEach(function (node) {
      if (node !== view.root) node.remove();
    });
    if (view.root.parentNode !== content) content.appendChild(view.root);
    return view;
  }

  function projectTitle(page) {
    var project = S.safeArray(page.projects).find(function (item) { return item.id === page.selectedProjectID; });
    return project ? "想在 " + project.title + " 中完成什么？" : "想完成什么？";
  }

  function updateFailure(view, detail, emit) {
    var key = detail && detail.taskID;
    if (view.failure.__taskID !== key) view.failure.open = false;
    view.failure.__taskID = key;
    var visible = detail && (detail.failureReason || detail.failureNextAction || detail.failureCode || detail.failureDiagnostic);
    view.failure.hidden = !visible;
    if (!visible) return;
    view.failure.firstChild.textContent = detail.failureReason || "会话执行失败";
    var signature = JSON.stringify([detail.failureNextAction, detail.failureCode, detail.failureDiagnostic, detail.canRestart]);
    view.failure.__detail = detail;
    view.failure.__emit = emit;
    if (view.failure.__signature === signature) return;
    view.failure.__signature = signature;
    var body = view.failure.__body;
    S.clear(body);
    if (detail.failureNextAction) body.appendChild(S.node("p", null, detail.failureNextAction));
    if (detail.failureCode) body.appendChild(S.node("p", "mono", detail.failureCode));
    if (detail.failureDiagnostic) body.appendChild(S.node("pre", "mono", detail.failureDiagnostic));
    if (detail.canRestart) {
      var retry = S.button("重试", null, {}, null, "small");
      retry.addEventListener("click", function () {
        var current = view.failure.__detail;
        if (!current.canRestart || P.isPending(current.taskID)) return;
        var request = { command: "restartTask", taskID: current.taskID, requestID: P.newRequestID(), input: null };
        P.begin(view.failure.__page, request);
        view.failure.__emit(request.command, {
          taskID: request.taskID, attachmentPaths: S.safeArray(current.attachmentPaths).slice()
        }, request.requestID);
      });
      body.appendChild(retry);
    }
  }

  function renderOpening(content, view, page) {
    var C = global.CodexBridgeDesktopWorkbenchConversation;
    var pending = page.pendingSubmission, nodes = [];
    var key = pending && JSON.stringify([page.selectedProjectID, pending.id]);
    if (pending) {
      if (view.pendingKey !== key) {
        view.pendingKey = key;
        view.pending = C.createMessage(pending);
      } else C.updateMessage(view.pending, pending);
      nodes.push(view.pending);
    } else {
      view.pendingKey = view.pending = null;
      if (page.awaitingTaskID) {
        if (!view.opening) view.opening = C.createLoading("正在打开会话…");
        nodes.push(view.opening);
      }
    }
    view.empty.hidden = nodes.length > 0;
    view.conversation.hidden = nodes.length === 0;
    Array.from(view.conversation.children).forEach(function (node) {
      if (nodes.indexOf(node) < 0) node.remove();
    });
    nodes.forEach(function (node) {
      if (node.parentNode !== view.conversation) view.conversation.appendChild(node);
    });
    content.__windowsConversationBlock = null;
    content.__windowsDetailCard = null;
    global.CodexBridgeDesktopWorkbenchActions.reset();
  }

  function render(content, page, emit) {
    var view = surface(content), detail = page.selectedTask;
    view.empty.hidden = !!detail;
    view.conversation.hidden = !detail;
    view.title.textContent = projectTitle(page);
    view.failure.__page = page;
    updateFailure(view, detail, emit);
    if (!detail) {
      renderOpening(content, view, page);
      return;
    }
    view.pendingKey = view.pending = null;
    global.CodexBridgeDesktopWorkbenchConversation.render(
      view.conversation, detail.conversation || [], page, emit, { owner: content });
    var block = content.__windowsConversationBlock;
    if (block) block.heading.hidden = true;
    else {
      var heading = view.conversation.querySelector(".subsection-title");
      if (heading) heading.hidden = true;
    }
  }

  global.CodexBridgeDesktopDSHConversation = { render: render };
}(window));
