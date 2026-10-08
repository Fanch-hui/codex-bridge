(function (global) {
  "use strict";

  var S = global.CodexBridgeDesktopPageSupport;
  var N = global.CodexBridgeDesktopNativePermissions;
  var P = global.CodexBridgeDesktopWorkbenchSubmissions;

  function renderStable(container, signature, render, preservesButtons) {
    if (!container.__renderState) {
      var state = container.__renderState = { pressed: false, signature: null, pending: null };
      container.addEventListener("pointerdown", function () { state.pressed = true; });
      container.addEventListener("keydown", function (event) {
        if ((event.key === "Enter" || event.key === " ") && event.target.closest("button")) {
          state.pressed = true;
        }
      });
      function release() {
        global.setTimeout(function () {
          state.pressed = false;
          var pending = state.pending;
          state.pending = null;
          if (pending) pending();
        }, 0);
      }
      container.addEventListener("focusout", release);
      global.addEventListener("pointerup", release);
      global.addEventListener("pointercancel", release);
      global.addEventListener("keyup", release);
      global.addEventListener("blur", release);
    }
    var state = container.__renderState;
    var active = document && document.activeElement;
    var focusedControl = active && container.contains(active)
      && /^(SELECT|INPUT|TEXTAREA|BUTTON)$/.test(String(active.tagName || "").toUpperCase());
    var focusedButton = active && String(active.tagName || "").toUpperCase() === "BUTTON";
    if (state.pressed || (focusedControl && !(preservesButtons && focusedButton))) {
      state.pending = function () { renderStable(container, signature, render, preservesButtons); };
      return;
    }
    if (state.signature === signature) return;
    render();
    state.signature = signature;
  }

  function renderContent(page, emit, development) {
    var content = document.getElementById("workbench-inspector-content");
    var inputs = Object.assign({}, page, {
      browser: page.browser && page.browser.canLoadEarlierConversation,
      development: !!development
    });
    var keys = Object.keys(inputs), previous = content.__contentInputs, revision = P.revision();
    if (previous && content.__submissionRevision === revision
      && keys.length === Object.keys(previous).length
      && keys.every(function (key) { return inputs[key] === previous[key]; })) return;
    content.__contentInputs = inputs;
    content.__submissionRevision = revision;
    renderStable(content, JSON.stringify([inputs, revision]), function () {
      var restore = global.CodexBridgeDesktopWorkbenchConversation.captureViewport(content, page);
      try {
        if (development) global.CodexBridgeDesktopDSHConversation.render(content, page, emit);
        else renderContentBody(content, page, emit);
      } finally { restore(); }
    }, true);
  }

  function prepareContentCard(content, page) {
    var incremental = global.CodexBridgeDesktopWorkbenchConversationIncremental;
    var detail = page.selectedTask;
    var keepConversation = incremental && detail
      && ((detail.conversation && detail.conversation.length) || detail.conversationState || P.hasEntries(page));
    var stableCard = keepConversation && content.__windowsDetailCard;
    if (stableCard) {
      Array.from(content.children).forEach(function (child) {
        if (child !== stableCard) child.remove();
      });
    } else {
      S.clear(content);
      content.__windowsDetailCard = null;
      if (!page.selectedTask) content.__windowsConversationBlock = null;
    }
    return { card: stableCard, keep: keepConversation };
  }

  function renderContentBody(content, page, emit) {
    var retained = prepareContentCard(content, page);
    if (!page.selectedTask) {
      global.CodexBridgeDesktopWorkbenchActions.reset();
      var empty = S.node("div", "workbench-empty-state");
      empty.appendChild(S.icon("sparkles", "empty-sparkle-icon"));
      empty.appendChild(S.node("h3", "empty-title", "选择 Agent 会话"));
      empty.appendChild(S.node("p", "empty-desc", "从顶部选择已有会话，或在 ChatGPT / Qwen 中委派任务。"));
      content.appendChild(empty);
      return;
    }
    var detail = page.selectedTask, row = S.safeArray(page.tasks).find(function (t) {
      return t.taskID === detail.taskID || (
        detail.sessionID &&
        t.sessionID === detail.sessionID &&
        t.providerID === detail.providerID &&
        t.projectID === page.selectedProjectID
      );
    }) || {};
    var remediationCard = N && N.remediationCard(detail, emit);
    if (remediationCard) content.appendChild(remediationCard);
    var card = retained.card || S.node("div", "page-card task-detail-card");
    var sections = global.CodexBridgeDesktopWorkbenchDetails.sections(card);
    if (retained.keep) content.__windowsDetailCard = card;
    global.CodexBridgeDesktopWorkbenchDetails.update(sections, detail);
    global.CodexBridgeDesktopWorkbenchActions.render(sections.actions, detail, row, emit);

    if ((detail.conversation && detail.conversation.length) || detail.conversationState || P.hasEntries(page)) {
      global.CodexBridgeDesktopWorkbenchConversation.render(
        sections.conversation, detail.conversation || [], page, emit, { owner: content });
      if (content.__windowsConversationBlock) content.__windowsConversationBlock.heading.hidden = false;
    }
    if (card.parentNode !== content) content.appendChild(card);
    else if (content.lastChild !== card) content.appendChild(card);
  }

  function renderShared(page, emit, development) {
    var footer = document.getElementById("workbench-inspector-footer");
    if (footer) footer.hidden = !!development;
    P.bind(page, function (follow) {
      renderContent(page, emit, development);
      if (!follow) return;
      var content = document.getElementById("workbench-inspector-content");
      content.scrollTop = content.scrollHeight;
      if (content.__conversationFollow) content.__conversationFollow.following = true;
    });
    if (!page) {
      if (development) {
        renderContent({}, emit, true);
        global.CodexBridgeDesktopWorkbenchApprovals.render({}, emit);
        return;
      }
      global.CodexBridgeDesktopWorkbenchActions.reset();
      global.CodexBridgeDesktopWorkbenchHeader.reset();
      global.CodexBridgeDesktopWorkbenchControls.render(null, emit);
      document.getElementById("chat-browser-slot").classList.add("browser-hidden");
      document.getElementById("browser-slot-note").textContent = "等待本机 Service 提供浏览器状态";
      return;
    }
    if (!development) global.CodexBridgeDesktopWorkbenchHeader.render(page, emit);
    global.CodexBridgeDesktopWorkbenchApprovals.render(page, emit);
    renderContent(page, emit, development);
    if (!development) global.CodexBridgeDesktopWorkbenchControls.render(page, emit);
  }

  global.CodexBridgeDesktopStableRender = renderStable;
  global.CodexBridgeDesktopWorkbenchPage = {
    render: function (page, emit, appUpdate, state) {
      if (global.CodexBridgeDesktopDSHWorkbench) {
        global.CodexBridgeDesktopDSHWorkbench.render(page, emit, state, renderShared);
      } else renderShared(page, emit);
    },
    renderShared: renderShared
  };
}(window));
